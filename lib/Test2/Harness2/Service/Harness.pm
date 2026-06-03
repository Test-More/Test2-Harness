package Test2::Harness2::Service::Harness;
use v5.38;

our $VERSION = '2.000000';

use Config qw/%Config/;
use File::Spec ();
use File::Path qw/make_path/;
use Time::HiRes qw/time/;

use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Collector qw/spawn_collector/;
use Test2::Harness2::Collector::Recorder;
use Test2::Harness2::Collector::Recorder::Test;
use Test2::Harness2::Collector::Monitor;
use Test2::Harness2::Scheduler;
use Test2::Harness2::Service::Sampler;

use Object::HashBase qw{
    <workdir
    <name
    <scheduler
    <monitor
    <running
    <run_stray
    <client_seq
    <sampler_interval
    <sampler_pid
    <system_load
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Service';

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Service::Harness - The main harness service.

=head1 DESCRIPTION

The global harness service. It consumes L<Test2::Harness2::Role::Service> for its
request loop, owns a L<Test2::Harness2::Scheduler> and a managed
L<Test2::Harness2::Collector::Monitor>, accepts requests from clients to queue
runs, launches each test job under a collector (fork + exec), and forwards
collector state updates to any subscribed client.

Initial version: one run and one job at a time, fork+exec launch, no resources
or retries.

=head1 REQUESTS

=over 4

=item queue_run => { files => [...] | jobs => [...], run_uuid?, stray? }

Queue a run; returns C<< {ok, run_uuid, run_ord, job_uuids} >>. C<files> is a
list of paths (bare jobs); C<jobs> is a list of producer job specs (scanned and
serialized via L<Test2::Harness2::Run::Job/TO_JSON>). When both are present
C<jobs> wins.

=item no_more_runs

Declare no further runs; the service stops once everything finishes.

=item subscribe

Register the requesting connection to receive collector transition frames
(forwarded by the monitor). Returns C<< {ok, monitor => $path} >>.

=item system_load => { load => \%snapshot }

A one-way report from the sampler process: store the latest system load snapshot
and announce it to the monitor. No response.

=back

=cut

sub init ($self) {
    $self->{+NAME}             //= 'harness';
    $self->{+SCHEDULER}        //= Test2::Harness2::Scheduler->new;
    $self->{+MONITOR}          //= Test2::Harness2::Collector::Monitor->new(listen => 1);
    $self->{+RUNNING}          //= {};
    $self->{+RUN_STRAY}        //= {};
    $self->{+CLIENT_SEQ}       //= 0;
    $self->{+SAMPLER_INTERVAL} //= 0.2;

    die "'workdir' is required\n" unless defined $self->{+WORKDIR} && length $self->{+WORKDIR};
    make_path($self->{+WORKDIR})  unless -d $self->{+WORKDIR};

    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item $self->service_tick

Called each loop iteration: poll the monitor, announce run lifecycle, mark
finished jobs done, launch pending jobs, sweep the monitor, and stop the service
once the scheduler reports everything done.

=item $self->service_on_start

Announce startup and spawn the load sampler (when C<sampler_interval> is set).

=item $self->service_on_stop

Stop the sampler process when the service loop exits.

=back

=cut

sub service_on_start ($self) {
    # Captured by the service's collector into the service events file.
    say "harness service '" . $self->{+NAME} . "' started (pid $$)";
    $self->_start_sampler if $self->{+SAMPLER_INTERVAL};
    return;
}

sub service_on_stop ($self) {
    # Reap the sampler before this process exits. Its collector inherited our
    # stdout/stderr write ends, so until it is gone our own collector never sees
    # EOF on those pipes (and would stall on its orphan timeout).
    if (my $pid = delete $self->{+SAMPLER_PID}) {
        kill 'TERM', $pid;
        waitpid($pid, 0);
    }
    return;
}

sub service_tick ($self) {
    my $mon   = $self->{+MONITOR};
    my $sched = $self->{+SCHEDULER};
    $mon->poll;

    # A run becomes 'running' once the scheduler starts considering its jobs.
    for my $run_uuid ($sched->new_started_runs) {
        $mon->announce({harness_run => {run_uuid => $run_uuid, state => 'running', stamp => time}});
    }

    # Mark a job done only once its collector is finalized: by then the monitor
    # has already forwarded the job's final_state frame to subscribers, so we
    # will not stop the service out from under a client still reading it.
    for my $job_uuid ($mon->new_finalized) {
        my $entry = delete $self->{+RUNNING}{$job_uuid} or next;
        $sched->mark_done($entry->{job});
        $self->_announce_run_progress($entry->{job}->run_uuid);
    }

    # A run is 'complete' once all of its jobs have finalized.
    for my $run_uuid ($sched->new_completed_runs) {
        $self->_announce_run_complete($run_uuid);
    }

    # Launch as many pending jobs as the scheduler allows.
    while (my $job = $sched->next_job) {
        $self->_launch_job($job);
    }

    $mon->sweep;

    $self->stop_service if $sched->all_done;

    return;
}

=over 4

=item $resp = $self->request_handler_queue_run($payload)

=item $resp = $self->request_handler_no_more_runs($payload)

=item $resp = $self->request_handler_subscribe($payload, $conn)

=item $resp = $self->request_handler_system_load($payload)

Request handlers; see L</REQUESTS>.

=back

=cut

sub request_handler_queue_run ($self, $payload, $conn = undef) {
    my $jobs  = $payload->{jobs};
    my $files = $payload->{files};

    my $have_jobs  = ref($jobs) eq 'ARRAY'  && @$jobs;
    my $have_files = ref($files) eq 'ARRAY' && @$files;

    return {ok => 0, error => "queue_run requires a non-empty 'jobs' or 'files' arrayref"}
        unless $have_jobs || $have_files;

    my $run = $self->{+SCHEDULER}->queue_run(
        ($have_jobs                    ? (jobs      => $jobs)                 : ()),
        ($have_files                   ? (files     => $files)                : ()),
        (defined $payload->{run_uuid}  ? (run_uuid  => $payload->{run_uuid})  : ()),
        (defined $payload->{job_uuids} ? (job_uuids => $payload->{job_uuids}) : ()),
    );

    $self->{+RUN_STRAY}{$run->run_uuid} = $payload->{stray} ? 1 : 0;

    $self->_announce_run_queued($run);

    return {
        ok        => 1,
        run_uuid  => $run->run_uuid,
        run_ord   => $run->run_ord,
        job_uuids => $run->job_uuids,
    };
}

sub request_handler_no_more_runs ($self, $payload = undef, $conn = undef) {
    $self->{+SCHEDULER}->no_more_runs;
    return {ok => 1};
}

sub request_handler_system_load ($self, $payload, $conn = undef) {
    my $load = $payload->{load} or return undef;
    $self->{+SYSTEM_LOAD} = $load;
    $self->{+MONITOR}->announce({harness_system => $load});
    return undef;    # one-way report; no response
}

sub request_handler_subscribe ($self, $payload, $conn) {
    my $name = 'client-' . $self->{+CLIENT_SEQ}++;
    $self->{+MONITOR}->add_proxy($name, $conn);
    return {ok => 1, monitor => $self->{+MONITOR}->socket_path};
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $self->_launch_job($job)

Fork + exec a collector running the job's test file, recording to the job's
events file and reporting transitions to the monitor. Marks the job running.

=item $path = $self->_job_events_file($job)

The job's events file: C<< $workdir/$run_ord/$job_ord/$try.jsonl.zst >> (dirs
created).

=item $self->_start_sampler

Fork the L<Test2::Harness2::Service::Sampler> under a collector (recording to
C<< $workdir/sampler.jsonl.zst >> and reporting transitions to the monitor),
pointed at this service's socket. Records its pid for shutdown.

=item $self->_announce_run_queued($run)

Announce a newly queued run (a C<harness_run> in state C<queued> with its job
list and counts) and one C<harness_job> per job (carrying the Run::Job spec) to
the monitor, so subscribers learn of the run before any collector starts.

=item $self->_announce_run_progress($run_uuid)

Announce updated completion/pass/fail counts for a run as its jobs finalize.

=item $self->_announce_run_complete($run_uuid)

Announce a run as C<complete> with final counts and an aggregate C<pass>.

=item ($job_count, $completed, $passed, $failed) = $self->_run_counts($run)

Tally a run's jobs from scheduler job state plus monitor final states.

=item $run = $self->_find_run($run_uuid)

The scheduler's L<Test2::Harness2::Run> with the given uuid, or C<undef>.

=back

=cut

sub _launch_job ($self, $job) {
    my $events   = $self->_job_events_file($job);
    my $stray    = $self->{+RUN_STRAY}{$job->run_uuid} ? 1 : 0;
    my $perl5lib = join($Config{path_sep} || ':', grep { defined && length } @INC, $ENV{PERL5LIB});

    my $pid = spawn_collector(
        is_test   => 1,
        name      => $job->relative,
        uuid      => $job->job_uuid,
        run_uuid  => $job->run_uuid,
        exec      => [$^X, $job->absolute],
        env       => {PERL5LIB => $perl5lib},
        processor => [
            ['Test2::Harness2::Collector::Assembler', emit_stray => $stray],
            'Test2::Harness2::Collector::Auditor',
        ],
        recorder => Test2::Harness2::Collector::Recorder::Test->new(
            events_file        => $events,
            transition_sockets => [$self->{+MONITOR}->socket_path],
        ),
    );

    $self->{+SCHEDULER}->mark_running($job);
    $self->{+RUNNING}{$job->job_uuid} = {pid => $pid, job => $job, events_file => $events};

    return;
}

sub _job_events_file ($self, $job) {
    my $dir = File::Spec->catdir($self->{+WORKDIR}, $job->run_ord, $job->job_ord);
    make_path($dir) unless -d $dir;
    return File::Spec->catfile($dir, $job->try . ".jsonl.zst");
}

sub _start_sampler ($self) {
    my $wd     = $self->{+WORKDIR};
    my $events = File::Spec->catfile($wd, 'sampler.jsonl.zst');

    my $pid = spawn_collector(
        is_test => 0,
        name    => 'sampler',
        uuid    => gen_uuid(),
        run     => sub {
            Test2::Harness2::Service::Sampler->new(
                workdir        => $wd,
                name           => 'sampler',
                interval       => $self->{+SAMPLER_INTERVAL},
                harness_socket => $self->service_socket_path,
            )->run;
        },
        recorder => Test2::Harness2::Collector::Recorder->new(
            events_file        => $events,
            transition_sockets => [$self->{+MONITOR}->socket_path],
        ),
    );

    $self->{+SAMPLER_PID} = $pid;
    return;
}

sub _announce_run_queued ($self, $run) {
    my $mon = $self->{+MONITOR};

    $mon->announce({
        harness_run => {
            run_uuid  => $run->run_uuid,
            state     => 'queued',
            job_uuids => $run->job_uuids,
            job_count => scalar(@{$run->jobs}),
            completed => 0,
            passed    => 0,
            failed    => 0,
            stamp     => time,
        },
    });

    for my $job (@{$run->jobs}) {
        $mon->announce({
            harness_job => {
                job_uuid => $job->job_uuid,
                run_uuid => $job->run_uuid,
                spec     => $job->TO_JSON,
                stamp    => time,
            },
        });
    }

    return;
}

sub _announce_run_progress ($self, $run_uuid) {
    my $run = $self->_find_run($run_uuid) or return;
    my ($job_count, $completed, $passed, $failed) = $self->_run_counts($run);

    $self->{+MONITOR}->announce({
        harness_run => {
            run_uuid  => $run_uuid,
            completed => $completed,
            passed    => $passed,
            failed    => $failed,
            stamp     => time,
        },
    });

    return;
}

sub _announce_run_complete ($self, $run_uuid) {
    my $run = $self->_find_run($run_uuid) or return;
    my ($job_count, $completed, $passed, $failed) = $self->_run_counts($run);

    $self->{+MONITOR}->announce({
        harness_run => {
            run_uuid  => $run_uuid,
            state     => 'complete',
            job_count => $job_count,
            completed => $completed,
            passed    => $passed,
            failed    => $failed,
            pass      => ($failed == 0 ? 1 : 0),
            stamp     => time,
        },
    });

    return;
}

sub _run_counts ($self, $run) {
    my $mon  = $self->{+MONITOR};
    my @jobs = @{$run->jobs};

    my ($completed, $passed) = (0, 0);
    for my $job (@jobs) {
        next unless $job->state eq 'done';
        $completed++;
        my $fs = $mon->final_state($job->job_uuid);
        $passed++ if $fs && $fs->{pass};
    }

    return (scalar(@jobs), $completed, $passed, $completed - $passed);
}

sub _find_run ($self, $run_uuid) {
    for my $run (@{$self->{+SCHEDULER}->runs}) {
        return $run if $run->run_uuid eq $run_uuid;
    }
    return undef;
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
