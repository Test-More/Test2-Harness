package App::Yath::Command::replay;
use strict;
use warnings;

our $VERSION = '1.000070';

use App::Yath::Options;
require App::Yath::Command::test;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw/+renderers <final_data <log_file <tests_seen <asserts_seen/;

include_options(
    'App::Yath::Options::Debug',
    'App::Yath::Options::Display',
    'App::Yath::Options::PreCommand',
);


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

sub init {
    my $self = shift;
    $self->SUPER::init() if $self->can('SUPER::init');

    $self->{+TESTS_SEEN}   //= 0;
    $self->{+ASSERTS_SEEN} //= 0;
}

sub run {
    my $self = shift;

    my $args      = $self->args;
    my $settings  = $self->settings;
    my $renderers = $self->App::Yath::Command::test::renderers;

    shift @$args if @$args && $args->[0] eq '--';

    $self->{+LOG_FILE} = shift @$args or die "You must specify a log file";
    die "'$self->{+LOG_FILE}' is not a valid log file" unless -f $self->{+LOG_FILE};
    die "'$self->{+LOG_FILE}' does not look like a log file" unless $self->{+LOG_FILE} =~ m/\.jsonl(\.(gz|bz2))?$/;

    my $jobs = @$args ? {map {$_ => 1} @$args} : undef;

    my $stream = Test2::Harness::Util::File::JSONL->new(name => $self->{+LOG_FILE});

    while (1) {
        my @events = $stream->poll(max => 1000) or last;

        for my $e (@events) {
            last unless defined $e;

            $self->{+TESTS_SEEN}++   if $e->{facet_data}->{harness_job_launch};
            $self->{+ASSERTS_SEEN}++ if $e->{facet_data}->{assert};

            if ($jobs && $e->{facet_data}->{harness_job_start}) {
              $jobs->{ $e->{job_id} } = 1
                if $jobs->{ $e->{facet_data}->{harness_job_start}{rel_file} }
                || $jobs->{ $e->{facet_data}->{harness_job_start}{abs_file} };
            }

            if (my $final = $e->{facet_data}->{harness_final}) {
                $self->{+FINAL_DATA} = $final;
            }
            else {
                next if $jobs && !$jobs->{$e->{job_id}};
                $_->render_event($e) for @$renderers;
            }
        }
    }

    $_->finish() for @$renderers;

    my $final_data = $self->{+FINAL_DATA} or die "Log did not contain final data!\n";

    $self->App::Yath::Command::test::render_final_data($final_data);
    $self->App::Yath::Command::test::render_summary($final_data->{pass});

    return $final_data->{pass} ? 0 : 1;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

