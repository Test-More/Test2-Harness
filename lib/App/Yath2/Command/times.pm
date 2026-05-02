package App::Yath2::Command::times;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Cwd qw/getcwd/;

use Test2::Util::Times qw/render_duration/;

use App::Yath2::LogArchive();
use App::Yath2::Streamer::Static();

use Role::Tiny::With;
with 'App::Yath2::Role::Command';
use Object::HashBase qw{
    <settings
    <args
    <env_vars
    <option_state
    <plugins
    <log
    <fields
};

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
);

sub args_include_tests { 0 }

sub summary { "Get per-test durations from a recorded log archive" }

sub group { 'log parsing' }

sub cli_args { "[--] LOG [Field1] [Field2]" }

sub description {
    return <<"    EOT";
Reads a recorded yath log and prints per-test durations sorted from shortest
to longest. LOG is either a .yath archive file or a directory that looks like
\$workdir/logs.

Available sort fields are 'total' (numeric, the wall-clock duration of each
test) and 'file' (alphabetic). Optional Field arguments override the default
sort precedence; subsequent fields break ties from earlier ones.

Per-test durations are derived from harness_job_start / harness_job_end
stamps emitted by App::Yath2::Streamer::Static. The granular startup/events/
cleanup breakdown that lived in the legacy log format is not present in the
new event stream.
    EOT
}

my @NUMERIC = qw/total/;
my %NUMERIC = map { $_ => 1 } @NUMERIC;

my @ALPHA = qw/file/;
my %ALPHA = map { $_ => 1 } @ALPHA;

my @FIELDS = (@NUMERIC, @ALPHA);
my %FIELDS = map { $_ => 1 } @FIELDS;

sub run {
    my $self = shift;

    my $args = $self->args;

    shift @$args if @$args && $args->[0] eq '--';

    my $log = shift @$args;
    unless (defined $log && length $log) {
        $log = App::Yath2::LogArchive->find_latest($self->{+SETTINGS});
        print STDERR "yath times: using latest archive: $log\n"
            if defined $log && length $log;
    }
    die "You must specify a log archive or directory\n"
        unless defined $log && length $log;
    die "Log source '$log' does not exist\n" unless -e $log;
    $self->{+LOG} = $log;

    my %seen;
    my @fields;
    for my $field (@$args, @FIELDS) {
        $field = lc($field);
        next if $seen{$field}++;
        die "'$field' is not a valid field\n" unless $FIELDS{$field};
        push @fields => $field;
    }
    $self->{+FIELDS} = \@fields;

    require App::Yath2::LogArchive;
    my @runs = App::Yath2::LogArchive->open(path => $log)->runs;
    die "No runs found in '$log'\n" unless @runs;

    my $streamer = App::Yath2::Streamer::Static->new(
        log    => $log,
        runs   => [@runs],
        global => 1,
    );

    my %job_state;
    my @jobs;
    $streamer->stream(
        callback => sub {
            my ($event) = @_;
            my $f = $event->facet_data // {};

            if (my $start = $f->{harness_job_start}) {
                my $jid = $start->{job_id} // $event->{job_id} // return;
                $job_state{$jid}{start} //= $start->{stamp}    // $event->stamp;
                $job_state{$jid}{file}  //= $start->{rel_file} // $start->{file};
                return;
            }

            return unless my $end = $f->{harness_job_end};

            my $jid  = $end->{job_id}   // $event->{job_id} // return;
            my $file = $end->{rel_file} // $end->{file}     // $job_state{$jid}{file};
            return unless $file;

            my $start = $job_state{$jid}{start};
            my $stop  = $end->{stamp} // $event->stamp;
            return unless defined $start && defined $stop;

            my $total = $stop - $start;
            return unless $total >= 0;

            push @jobs => {file => $file, time => {total => $total}};
        },
    );

    my @rows;
    my $totals = {file => 'TOTAL', total => 0};

    @jobs = sort { $self->sort_compare($a, $b) } @jobs;

    for my $job (@jobs) {
        my $data = $job->{time};
        push @rows => $self->build_row({%$data, file => $job->{file}});
        $totals->{$_} += $data->{$_} for @NUMERIC;
    }

    push @rows => [map { '--' } @fields];
    push @rows => $self->build_row($totals);

    require Term::Table;
    my $table = Term::Table->new(
        header => [map { ucfirst($_) } @fields],
        rows   => \@rows,
    );

    print "$_\n" for $table->render;

    return 0;
}

sub build_row {
    my $self = shift;
    my ($data) = @_;

    return [map { $NUMERIC{$_} && defined($data->{$_}) ? render_duration($data->{$_}) : $data->{$_} } @{$self->{+FIELDS}}];
}

sub sort_compare {
    my $self = shift;
    my ($ja, $jb) = @_;

    my $order = $self->{+FIELDS};

    my $ta = $ja->{time};
    my $tb = $jb->{time};

    for my $field (@$order) {
        my $fa = $field eq 'file' ? $ja->{file} : $ta->{$field};
        my $fb = $field eq 'file' ? $jb->{file} : $tb->{$field};

        my $da = defined $fa;
        my $db = defined $fb;

        next unless $da || $db;
        return 1  if $da && !$db;
        return -1 if $db && !$da;

        my $delta = $ALPHA{$field} ? lc($fa) cmp lc($fb) : $fa <=> $fb;
        return $delta if $delta;
    }

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

