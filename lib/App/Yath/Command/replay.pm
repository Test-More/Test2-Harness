package App::Yath::Command::replay;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Harness::Util::File::JSONL;

use parent 'App::Yath::Command::run';
use Test2::Harness::Util::HashBase qw{
    +renderers
    <final_data
    <log_file
    <tests_seen
    <asserts_seen
};

use Getopt::Yath;

include_options(
    'App::Yath::Options::Renderer',
);

include_options(
    'App::Yath::Options::Renderer',
);

option_group {group => 'run', category => "Run Options"} => sub {
    option run_auditor => (
        type => 'Scalar',
        default => 'Test2::Harness::Collector::Auditor::Run',
        normalize => sub { fqmod($_[0], 'Test2::Harness::Collector::Auditor::Run') },
        description => 'Auditor class to use when auditing the overall test run',
    );
};

sub load_renderers     { 1 }
sub load_plugins       { 0 }
sub load_resources     { 0 }
sub args_include_tests { 0 }

sub group { 'log' }

sub summary { "Replay a test run from an event log" }

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

    my $args     = $self->args;
    my $settings = $self->settings;

    shift @$args if @$args && $args->[0] eq '--';

    $self->{+LOG_FILE} = shift @$args or die "You must specify a log file";
    die "'$self->{+LOG_FILE}' is not a valid log file" unless -f $self->{+LOG_FILE};
    die "'$self->{+LOG_FILE}' does not look like a log file" unless $self->{+LOG_FILE} =~ m/\.jsonl(\.(gz|bz2))?$/;

    my $stream = Test2::Harness::Util::File::JSONL->new(name => $self->{+LOG_FILE});
    while (1) {
        my ($e) = $stream->poll(max => 1);
        die "Could not find run_id in log.\n" unless $e;

        my $run_id = Test2::Harness::Event->new($e)->run_id or next;

        $settings->run->create_option(run_id => $run_id);
        last;
    }

    # Reset the stream
    $stream = Test2::Harness::Util::File::JSONL->new(name => $self->{+LOG_FILE});

    $self->start_plugins_and_renderers();

    my $jobs = @$args ? {map {$_ => 1} @$args} : undef;

    while (1) {
        my @events = $stream->poll(max => 1000) or last;

        for my $e (@events) {
            last unless defined $e;

            if ($jobs) {
                my $f = $e->{facet_data}->{harness_job_start} // $e->{facet_data}->{harness_job_queued};
                if ($f && !$jobs->{$e->{job_id}}) {
                    for my $field (qw/rel_file abs_file file/) {
                        my $file = $f->{$field} or next;
                        next unless $jobs->{$file};
                        $jobs->{$e->{job_id}} = 1;
                        last;
                    }
                }

                next unless $jobs->{$e->{job_id}};
            }

            $self->handle_event($e);
        }
    }

    my $exit = $self->stop_plugins_and_renderers();
    return $exit;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

