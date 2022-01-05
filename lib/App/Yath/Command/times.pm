package App::Yath::Command::times;
use strict;
use warnings;

our $VERSION = '1.000095';

use Test2::Util::Times qw/render_duration/;

use Test2::Harness::Util::File::JSONL;

use App::Yath::Options;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw/-log_file <fields/;

include_options(
    'App::Yath::Options::Debug',
);

sub summary { "Get times from a test log" }

sub group { 'log' }

sub cli_args { "[--] event_log.jsonl[.gz|.bz2] [Field1] [Field2]" }

sub description {
    return <<"    EOT";
This command will consume the log of a previous run, and output all timing data
from shortest test to longest. You can specify a sort order by listing fields
in your desired order after the log file on the command line.
    EOT
}

my @NUMERIC = qw/total startup events cleanup/;
my %NUMERIC = map { $_ => 1 } @NUMERIC;

my @ALPHA = qw/file/;
my %ALPHA = map { $_ => 1 } @ALPHA;

my @FIELDS = (@NUMERIC, @ALPHA);
my %FIELDS = map { $_ => 1 } @FIELDS;

sub run {
    my $self = shift;

    my $args = $self->args;

    shift @$args if @$args && $args->[0] eq '--';

    $self->{+LOG_FILE} = shift @$args or die "You must specify a log file";
    die "'$self->{+LOG_FILE}' is not a valid log file" unless -f $self->{+LOG_FILE};
    die "'$self->{+LOG_FILE}' does not look like a log file" unless $self->{+LOG_FILE} =~ m/\.jsonl(\.(gz|bz2))?$/;

    my %seen;
    my @fields;
    for my $field (@$args, @FIELDS) {
        $field = lc($field);
        next if $seen{$field}++;
        die "'$field' is not a valid field\n" unless $FIELDS{$field};
        push @fields => $field;
    }

    $self->{+FIELDS} = \@fields;

    my $stream = Test2::Harness::Util::File::JSONL->new(name => $self->{+LOG_FILE});

    my @jobs;
    while (1) {
        my @events = $stream->poll(max => 1000) or last;

        for my $event (@events) {
            my $stamp  = $event->{stamp}      or next;
            my $job_id = $event->{job_id}     or next;
            my $f      = $event->{facet_data} or next;

            next unless $f->{harness_job_end};

            my $job = {};
            $job->{file} = $f->{harness_job_end}->{rel_file}        if $f->{harness_job_end} && $f->{harness_job_end}->{rel_file};
            $job->{time} = $f->{harness_job_end}->{times}->{totals} if $f->{harness_job_end} && $f->{harness_job_end}->{times};

            push @jobs => $job;
        }
    }

    my @rows;
    my $totals = {file => 'TOTAL'};

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
        my $fa = $ta->{$field};
        my $fb = $tb->{$field};

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

