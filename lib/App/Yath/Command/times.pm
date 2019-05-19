package App::Yath::Command::times;
use strict;
use warnings;

our $VERSION = '0.001076';

use Test2::Util qw/pkg_to_file/;

use Test2::Harness::Feeder::JSONL;
use Test2::Harness::Run;
use Test2::Harness;

use Term::Table;

use List::Util qw/min max/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub summary { "Get times from a test log" }

sub group { 'log' }

sub has_runner  { 0 }
sub has_logger  { 0 }
sub has_display { 0 }
sub show_bench  { 0 }

sub cli_args { "[--] event_log.jsonl[.gz|.bz2]" }

sub description {
    return <<"    EOT";
This command will consume the log of a previous run, and output all timing data
from shortest test to longest.
    EOT
}

my @NUMERIC = qw/total startup events cleanup/;
my %NUMERIC = map { $_ => 1 } @NUMERIC;

my @ALPHA = qw/file/;
my %ALPHA = map { $_ => 1 } @ALPHA;

my @FIELDS = (@NUMERIC, @ALPHA);
my %FIELDS = map { $_ => 1 } @FIELDS;

sub options {
    my $self = shift;

    return (
        $self->SUPER::options(),

        {
            spec    => 's|sort=s',
            field   => 'sort',
            used_by => {all => 1},
            section => 'Display Options',
            usage   => ['-s total,events', '--sort total,events'],
            summary => ['Columns to sort by'],
            default => sub { [qw/total startup events cleanup file/] },
            long_desc => "Allowed column names: total, startup, events, cleanup, file",
            action => sub {
                my $self = shift;
                my ($settings, $field, $arg, $opt) = @_;

                my %seen;
                my @order = grep { !$seen{$_}++ } split(',', $arg), @FIELDS;

                my @bad = grep {!$FIELDS{$_}} @order;

                die "Invalid sort fields: " . join(', ', @bad) . "\n" if @bad;

                $settings->{$field} = \@order;
            }
        },
    );
}

sub handle_list_args {
    my $self = shift;
    my ($list) = @_;

    my $settings = $self->{+SETTINGS};

    my ($log) = @$list;

    $settings->{log_file} = $log;

    die "You must specify a log file.\n"
        unless $log;

    die "Invalid log file: '$log'"
        unless -f $log;
}

sub run_command {
    my $self = shift;

    my $settings = $self->{+SETTINGS};

    my $feeder = $self->feeder;

    my %jobs;

    while (1) {
        my @events = $feeder->poll(1000) or last;
        for my $event (@events) {
            my $stamp  = $event->{stamp}      or next;
            my $job_id = $event->{job_id}     or next;
            my $f      = $event->{facet_data} or next;

            my $job = $jobs{$job_id} ||= {};

            $job->{file} ||= File::Spec->abs2rel($f->{harness_job}->{file}) if $f->{harness_job};

            $job->{start} = $job->{start} ? min($job->{start}, $stamp) : $stamp;
            $job->{stop} = $job->{stop} ? max($job->{stop}, $stamp) : $stamp;

            if ($f->{plan} || $f->{assert} || $f->{errors} || $f->{info}) {
                $job->{first} = $job->{first} ? min($job->{first}, $stamp) : $stamp;
                $job->{last} = $job->{last} ? max($job->{last}, $stamp) : $stamp;
            }
        }
    }

    for my $set (values %jobs) {
        next unless $set->{stop} && $set->{start} && $set->{last} && $set->{first};

        $set->{total}   = $set->{stop} - $set->{start}  if $set->{stop}  && $set->{start};
        $set->{events}  = $set->{last} - $set->{first}  if $set->{last}  && $set->{first};
        $set->{startup} = $set->{first} - $set->{start} if $set->{first} && $set->{start};
        $set->{cleanup} = $set->{stop} - $set->{last}   if $set->{stop}  && $set->{last};
    }

    my @rows;
    my $totals = {file => 'TOTAL'};

    my @jobs = sort { $self->sort_compare($a, $b) } values %jobs;

    for my $job (@jobs) {
        push @rows => $self->build_row($job);
        $totals->{$_} += $job->{$_} for @NUMERIC;
    }

    push @rows => [map { '--' } @FIELDS];
    push @rows => $self->build_row($totals);

    my $table = Term::Table->new(
        header => [map {ucfirst($_)} @{$settings->{sort}}],
        rows   => \@rows,
    );

    print "$_\n" for $table->render;
}

sub build_row {
    my $self = shift;
    my ($data) = @_;

    my $settings = $self->{+SETTINGS};

    return [ map { $NUMERIC{$_} ? render_duration($data->{$_}) : $data->{$_} } @{$settings->{sort}}];
}

sub sort_compare {
    my $self = shift;
    my ($ja, $jb) = @_;

    my $settings = $self->{+SETTINGS};
    my $order = $settings->{sort};

    for my $field (@$order) {
        my $fa = $a->{$field};
        my $fb = $b->{$field};

        my $da = defined $fa;
        my $db = defined $fb;

        next unless $da || $db;
        return 1 if $da && !$db;
        return -1 if $db && !$da;

        my $delta = $ALPHA{$field} ? lc($fa) cmp lc($fb) : $fa <=> $fb;
        return $delta if $delta;
    }

    return 0;
}

sub feeder {
    my $self = shift;

    my $settings = $self->{+SETTINGS};

    my $feeder = Test2::Harness::Feeder::JSONL->new(file => $settings->{log_file});

    return ($feeder);
}

sub render_duration {
    my ($time) = @_;

    return 'NA' unless defined $time;

    if ($time < 10) {
        return sprintf('%1.5fs', $time);
    }
    elsif ($time < 60) {
        return sprintf('%2.4fs', $time);
    }
    else {
        my $msec  = substr(sprintf('%0.2f', $time - int($time)), -2, 2);
        my $secs  = $time % 60;
        my $mins  = int($time / 60) % 60;
        my $hours = int($time / 60 / 60) % 24;
        my $days  = int($time / 60 / 60 / 24);

        my @units = (qw/d h m/, '');

        my $duration = '';
        for my $t ($days, $hours, $mins, $secs) {
            my $u = shift @units;
            next unless $t || $duration;
            $duration = join ':' => grep { length($_) } $duration, sprintf('%02u%s', $t, $u);
        }

        $duration ||= '0';
        $duration .= ".$msec" if int($msec);
        $duration .= 's';

        return $duration;
    }
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command::times

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 COMMAND LINE USAGE

B<THIS SECTION IS AUTO-GENERATED AT BUILD>

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
