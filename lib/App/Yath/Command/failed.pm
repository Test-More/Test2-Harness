package App::Yath::Command::failed;
use strict;
use warnings;

our $VERSION = '1.000065';

use Test2::Util::Table qw/table/;
use Test2::Harness::Util::File::JSONL;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw{<log_file};

use App::Yath::Options;

option brief => (
    prefix => 'display',
    category => 'Display Options',
    description => 'Show only files that failed, newline separated, no other output. If a file dailed once but passed on a retry it will NOT be shown.',
);

sub summary { "Replay a test run from an event log" }

sub group { 'log' }

sub cli_args { "[--] event_log.jsonl[.gz|.bz2] [job1, job2, ...]" }

sub description {
    return <<"    EOT";
This yath command will re-run the harness against an event log produced by a
previous test run. The only required argument is the path to the log file,
which maybe compressed. Any extra arguments are assumed to be job id's. If you
list any jobs, only listed jobs will be processed.

This command accepts all the same renderer/formatter options that the 'test'
command accepts.
    EOT
}

sub run {
    my $self = shift;

    my $settings = $self->settings;
    my $args     = $self->args;

    shift @$args if @$args && $args->[0] eq '--';

    $self->{+LOG_FILE} = shift @$args or die "You must specify a log file";
    die "'$self->{+LOG_FILE}' is not a valid log file" unless -f $self->{+LOG_FILE};
    die "'$self->{+LOG_FILE}' does not look like a log file" unless $self->{+LOG_FILE} =~ m/\.jsonl(\.(gz|bz2))?$/;

    my $stream = Test2::Harness::Util::File::JSONL->new(name => $self->{+LOG_FILE});

    my %failed;

    while(1) {
        my @events = $stream->poll(max => 1000) or last;

        for my $event (@events) {
            my $stamp  = $event->{stamp}      or next;
            my $job_id = $event->{job_id}     or next;
            my $f      = $event->{facet_data} or next;

            next unless $f->{harness_job_end};
            next unless $f->{harness_job_end}->{fail} || $failed{$job_id};

            push @{$failed{$job_id}} => $f->{harness_job_end};
        }
    }

    my $rows = [];
    while (my ($job_id, $ends) = each %failed) {
        if ($settings->display->brief) {
            print $ends->[-1]->{rel_file}, "\n" if $ends->[-1]->{fail};
        }
        else {
            push @$rows => [$job_id, scalar(@$ends), $ends->[-1]->{rel_file}, $ends->[-1]->{fail} ? "NO" : "YES"];
        }
    }

    return 0 if $settings->display->brief;

    unless (@$rows) {
        print "\nNo jobs failed!\n";
        return 0;
    }

    print "\nThe following jobs failed at least once:\n";
    print join "\n" => table(
        header => ['Job ID', 'Times Run', 'Test File', "Succeeded Eventually?"],
        rows   => $rows,
    );
    print "\n";

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

