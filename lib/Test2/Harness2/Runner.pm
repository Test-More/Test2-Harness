package Test2::Harness2::Runner;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use POSIX qw/:sys_wait_h/;
use File::Spec ();
use File::Path qw/make_path/;
use File::Temp qw/tempdir/;
use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Util qw/now_dt/;
use Cwd qw/abs_path/;

use Test2::Harness2;
use Test2::Harness2::Scheduler;
use Test2::Harness2::Collector;
use Test2::Harness2::Collector::Auditor::Test;

use Object::HashBase qw{
    <connect_spec
    <runner_uuid
    <service_uuid
    <workdir
    +harness
    +scheduler
    -running
    -active_runs
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Service';

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner - Service that runs queued tests one at a time.

=head1 DESCRIPTION

The runner is a L<Test2::Harness2::Role::Service>: each tick it reaps finished
test collectors, then (while running) launches the next queued job by forking
a test collector that execs the test file with a
L<Test2::Harness2::Collector::Auditor::Test> as its processor. One test runs at
a time. When every job in a run is resolved the runner stamps the run's
C<passed> verdict and C<stopped> time.

Each process the runner forks builds its own L<Test2::Harness2> connection so
no DBI handle is shared across a fork.

The runner's service-row C<mode> is observed every tick: C<stop> drains
outstanding work then stops the loop, C<kill> signals running test collectors
and stops.

=head1 SYNOPSIS

    use Test2::Harness2::Runner;

    Test2::Harness2::Runner->new(
        connect_spec => {flavor => 'sqlite', db_path => $path},
        runner_uuid  => $runner_uuid,
    )->run;

=head1 ATTRIBUTES

=over 4

=item connect_spec

Required. A plain hashref of constructor arguments for C<Test2::Harness2>,
as returned by C<< Test2::Harness2->connect_spec >>. Each forked process
rebuilds its own C<Test2::Harness2> connection from this spec so no DBI
handle is shared across a fork. For SQLite harnesses this will be
C<< { flavor => 'sqlite', db_path => $path } >>; for ephemeral or DSN-based
harnesses it carries the live C<dsn>, C<username>, and C<password>.

=item runner_uuid

Required. UUID of the runner this service drives. Only this runner's jobs are
scheduled.

=item service_uuid

UUID of the service row whose C<mode> governs the loop. Defaults to
C<runner_uuid>.

=item workdir

Directory for per-test event files. Defaults to a fresh temp directory cleaned
up on exit.

=back

=cut

sub init ($self) {
    croak "'connect_spec' is required" unless $self->{+CONNECT_SPEC};
    croak "'runner_uuid' is required"  unless $self->{+RUNNER_UUID};
    $self->{+SERVICE_UUID} //= $self->{+RUNNER_UUID};
    $self->{+WORKDIR}      //= tempdir(CLEANUP => 1);
    make_path($self->{+WORKDIR}) unless -d $self->{+WORKDIR};
    $self->{+RUNNING}     = {};
    $self->{+ACTIVE_RUNS} = {};
    return;
}

=pod

=head1 PUBLIC METHODS

=over 4

=item $h = $runner->harness

This process's own L<Test2::Harness2>, built lazily so the connection belongs
to whichever process first asks for it.

=item $con = $runner->con

This process's harness connection.

=item $sched = $runner->scheduler

The L<Test2::Harness2::Scheduler> for this runner, built lazily on this
process's connection.

=cut

sub harness ($self) {
    return $self->{+HARNESS} //= Test2::Harness2->new(%{$self->{+CONNECT_SPEC}});
}

sub con ($self) { return $self->harness->connection }

sub scheduler ($self) {
    return $self->{+SCHEDULER} //= Test2::Harness2::Scheduler->new(
        con         => $self->con,
        runner_uuid => $self->{+RUNNER_UUID},
    );
}

=pod

=item $mode = $runner->mode

The runner service row's current C<mode> (C<run> / C<stop> / C<kill>),
defaulting to C<run> when the row is missing or unset.

=cut

sub mode ($self) {
    my $svc = $self->con->handle('service')->by_id($self->{+SERVICE_UUID}) or return 'run';
    return $svc->field('mode') // 'run';
}

=pod

=item $did_work = $runner->tick

One service iteration: reap finished collectors, act on C<kill> mode, launch
the next job (one test at a time), and settle completed runs. Returns true
when work was done.

=cut

sub tick ($self) {
    my $reaped = $self->_reap_finished;

    if ($self->mode eq 'kill') {
        $self->_begin_kill;
        return 1;
    }

    return $reaped if keys %{$self->{+RUNNING}};

    if (my $job = $self->scheduler->next_job) {
        $self->_launch_job($job);
        return 1;
    }

    $self->_settle_runs;
    return $reaped;
}

=pod

=item $bool = $runner->should_stop

True once the loop should exit: in C<kill> mode with nothing running, or in
C<stop> mode with no running tests and no remaining work (runs are settled
first).

=back

=cut

sub should_stop ($self) {
    my $mode = $self->mode;
    return 1 if $mode eq 'kill' && !keys %{$self->{+RUNNING}};
    return 0 unless $mode eq 'stop';
    return 0 if keys %{$self->{+RUNNING}};
    return 0 if $self->scheduler->next_job;
    $self->_settle_runs;
    return 1;
}

=pod

=head1 PRIVATE METHODS

=over 4

=item $runner->_launch_job($job)

Start a try for the job, insert its collector and events-artifact rows, then
fork a test-collector process. The child builds its own connection, re-fetches
the rows, and runs the collector with a per-test auditor that execs the test
file.

=cut

sub _launch_job ($self, $job) {
    my $con      = $self->con;
    my $try      = $self->scheduler->start_try($job);
    my $try_uuid = $try->field('try_uuid');
    my $job_uuid = $job->field('job_uuid');
    my $run_uuid = $job->field('run_uuid');
    my $file     = $con->handle('test_file')->by_id($job->field('test_file_id'))->field('test_file');

    $self->{+ACTIVE_RUNS}{$run_uuid} = 1;

    my $events = File::Spec->catfile($self->{+WORKDIR}, gen_uuid() . '.jsonl.zst');

    my $crow = $con->handle('collector')->insert({
        service_uuid => $self->{+SERVICE_UUID},
        try_uuid     => $try_uuid,
        mode         => 'run',
    });
    my $arow = $con->handle('artifact')->insert({
        artifact_uuid => gen_uuid(),
        run_uuid      => $run_uuid,
        try_uuid      => $try_uuid,
        name          => 'events',
        type          => 'jsonl.zst',
        local_path    => $events,
    });
    my $collector_id  = $crow->field('collector_id');
    my $artifact_uuid = $arow->field('artifact_uuid');

    my $pid = fork // die "fork: $!";
    if ($pid == 0) {
        my $exit = 255;
        my $ok   = eval {
            # Test-collector parent process: its own fresh connection + rows.
            my $ccon    = Test2::Harness2->new(%{$self->{+CONNECT_SPEC}})->connection;
            my $ctry    = $ccon->handle('try')->by_id($try_uuid);
            my $ccrow   = $ccon->handle('collector')->by_id($collector_id);
            my $carow   = $ccon->handle('artifact')->by_id($artifact_uuid);
            my $auditor = Test2::Harness2::Collector::Auditor::Test->new(try_row => $ctry, con => $ccon);

            # Build -I flags from the process's @INC, converting any
            # relative paths to absolute so exec'd tests work even when cwd
            # changes between now and exec time.
            my @inc_flags = map { ('-I', abs_path($_) // $_) }
                grep { !ref($_) } @INC;

            $exit = Test2::Harness2::Collector->start(
                is_test       => 1,
                events_file   => $events,
                exec_command  => [$^X, @inc_flags, $file],
                processor     => $auditor,
                collector_row => $ccrow,
                artifact_row  => $carow,
            );
            1;
        };
        warn "test collector child failed: $@\n" unless $ok;
        POSIX::_exit($ok ? ($exit ? $exit : 0) : 255);
    }

    $self->{+RUNNING}{$pid} = {job_uuid => $job_uuid, try_uuid => $try_uuid};
    return;
}

=pod

=item $count = $runner->_reap_finished

Non-blocking reap of finished test collectors. For each, ask the scheduler to
finish the try (retry or resolve the job). Returns the number reaped.

=cut

sub _reap_finished ($self) {
    my $count = 0;
    while ((my $pid = waitpid(-1, WNOHANG)) > 0) {
        my $info = delete $self->{+RUNNING}{$pid} or next;
        my $con  = $self->con;
        my $job  = $con->handle('job')->by_id($info->{job_uuid});
        my $try  = $con->handle('try')->by_id($info->{try_uuid});
        $self->scheduler->finish_try($job, $try) if $job && $try;
        $count++;
    }
    return $count;
}

=pod

=item $runner->_settle_runs

For each active run whose jobs are all resolved, stamp the run's C<passed>
verdict (the AND of its jobs) and C<stopped> time, once.

=cut

sub _settle_runs ($self) {
    my $con = $self->con;
    for my $run_uuid (keys %{$self->{+ACTIVE_RUNS}}) {
        next unless $self->scheduler->run_complete($run_uuid);
        my $run = $con->handle('run')->by_id($run_uuid) or next;
        next if defined $run->field('stopped');

        my @jobs   = $con->handle('job', where => {run_uuid => $run_uuid})->all;
        my $passed = 1;
        $passed &&= $_->field('passed') ? 1 : 0 for @jobs;
        $run->update({passed => $passed, stopped => now_dt()});
    }
    return;
}

=pod

=item $runner->_begin_kill

Signal every running test collector: flip its collector row to C<kill> mode
and send it C<SIGTERM>.

=back

=cut

sub _begin_kill ($self) {
    my $con = $self->con;
    for my $pid (keys %{$self->{+RUNNING}}) {
        my $info = $self->{+RUNNING}{$pid};
        my $crow = $con->handle('collector', where => {try_uuid => $info->{try_uuid}})->one;
        $crow->update({mode => 'kill'}) if $crow;
        kill 'TERM', $pid;
    }
    return;
}

1;

__END__

=pod

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
