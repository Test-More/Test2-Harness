package Test2::Harness2;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Path qw/make_path/;
use Time::HiRes qw/time/;
use Test2::Util::UUID qw/gen_uuid/;
use POSIX qw/WNOHANG/;

use constant HAS_LINUX_PRCTL => eval { require Linux::Prctl; 1 } ? 1 : 0;

use Test2::Harness2::Collector;
use Test2::Harness2::Run;

use Test2::Harness2::Util::HashBase qw{
    <workdir
    <name
    <job_id
    <loggers
    <test_auditor
    <test_loggers
    <kill_timeout
    <parent_pids
    +state
    +queue
    +current
    +finish_after_initial_run
    +emitter
    +watch_pids_ref
};

use Role::Tiny::With;
with 'IPC::Manager::Role::Service';

sub init {
    my $self = shift;

    my $wd = $self->{+WORKDIR} // croak "'workdir' is a required attribute";
    croak "workdir '$wd' does not exist or is not a directory" unless -d $wd;
    croak "workdir '$wd' already contains services/ -- refusing to clobber"
        if -e "$wd/services";
    croak "workdir '$wd' already contains runs/ -- refusing to clobber"
        if -e "$wd/runs";

    make_path("$wd/services");

    $self->{+NAME}           //= 'harness';
    $self->{+JOB_ID}         //= gen_uuid();
    $self->{+KILL_TIMEOUT}   //= 15;
    $self->{+PARENT_PIDS}    //= [];
    $self->{+STATE}          //= 'running';
    $self->{+QUEUE}          //= [];
    $self->{+WATCH_PIDS_REF} //= [@{$self->{+PARENT_PIDS}}];

    $self->{+LOGGERS} //= [
        [
            'Test2::Harness2::Collector::Logger::JSONL',
            output_file => "$wd/services/$self->{+NAME}.jsonl",
        ],
    ];
    $self->{+TEST_AUDITOR} //= 'Test2::Harness2::Collector::Auditor::Test';
    $self->{+TEST_LOGGERS} //= ['Test2::Harness2::Collector::Logger::JSONL'];
}

# IPC::Manager::Role::Service required methods. Fleshed out in later tasks.
sub orig_io    { {} }
sub ipcm_info  { $_[0]->{ipcm_info} }
sub pid        { $_[0]->{pid} //= $$ }
sub set_pid    { $_[0]->{pid} = $_[1] }
sub watch_pids { $_[0]->{+WATCH_PIDS_REF} }

# IPC::Manager calls handle_request($req, $msg) where $req is a hashref
# with a 'request' key holding the request-name string, e.g.
# { request => 'status', ipcm_request_id => '...', ... }.
# We dispatch on $req->{request}.
sub handle_request {
    my ($self, $req, $msg) = @_;

    my $name = $req->{request};

    return $self->handle_status_request               if $name eq 'status';
    return $self->handle_queue_test_run_request($req) if $name eq 'queue_test_run';
    return $self->handle_finish_request               if $name eq 'finish';
    return $self->handle_terminate_request            if $name eq 'Terminate';
    return $self->handle_detach_request($req)         if $name eq 'Detach';

    return {ok => 0, error => "unknown request '$name'"};
}

sub handle_queue_test_run_request {
    my ($self, $payload) = @_;
    $payload //= {};

    return {ok => 0, error => 'service not accepting new runs'}
        if $self->{+STATE} ne 'running';

    my $files = $payload->{files} || [];
    return {ok => 0, error => "'files' must be a non-empty arrayref"}
        unless ref($files) eq 'ARRAY' && @$files;

    my $run = Test2::Harness2::Run->from_files(
        files => $files,
        (defined $payload->{run_id} ? (run_id => $payload->{run_id}) : ()),
    );

    push @{$self->{+QUEUE}} => $run;

    return {ok => 1, run_id => $run->run_id};
}

sub handle_status_request {
    my $self = shift;

    my $queue = [
        map { {
            run_id  => $_->run_id,
            pending => [@{$_->pending}],
            running => [@{$_->running}],
            done    => [@{$_->done}],
        } } @{$self->{+QUEUE}}
    ];

    my $running;
    if (my $cur = $self->{+CURRENT}) {
        $running = {
            run_id    => $cur->{run}->run_id,
            job_id    => $cur->{job}->job_id,
            test_file => $cur->{job}->test_file,
            pid       => $cur->{pid},
            started   => $cur->{started_at},
        };
    }

    return {
        service => {
            name    => $self->{+NAME},
            pid     => $$,
            job_id  => $self->{+JOB_ID},
            workdir => $self->{+WORKDIR},
            state   => $self->{+STATE},
        },
        queue   => $queue,
        running => $running,
    };
}

sub handle_finish_request {
    my $self = shift;
    return {ok => 0} unless $self->{+STATE} eq 'running';
    $self->{+STATE} = 'finishing';
    return {ok => 1};
}

sub handle_terminate_request {
    my $self = shift;
    $self->_perform_hard_stop;
    return {ok => 1};
}

sub handle_detach_request {
    my ($self, $payload) = @_;
    my $pid = $payload->{pid};
    return {ok => 0, error => "missing 'pid'"} unless defined $pid;

    $self->{+WATCH_PIDS_REF} = [grep { $_ != $pid } @{$self->{+WATCH_PIDS_REF}}];
    return {ok => 1};
}

sub _check_current_completion {
    my $self = shift;
    my $cur  = $self->{+CURRENT} or return;

    my $handle = $cur->{handle};
    return unless $handle->is_done;

    # Move the job from running to done.
    $cur->{run}->mark_done($cur->{job}->job_id);

    # If the whole run is complete, pop it from the queue.
    if ($cur->{run}->is_complete) {
        my $run_id = $cur->{run}->run_id;
        $self->{+QUEUE} = [grep { $_->run_id ne $run_id } @{$self->{+QUEUE}}];

        # Flip to finishing if requested (Task 15 builds on this).
        $self->{+STATE} = 'finishing'
            if $self->{+FINISH_AFTER_INITIAL_RUN}
            && $self->{+STATE} eq 'running';
    }

    delete $self->{+CURRENT};
}

sub _perform_hard_stop {
    my $self = shift;

    $self->{+STATE} = 'terminating';
    $self->{+QUEUE} = [];

    my $timeout = $self->{+KILL_TIMEOUT};

    my @pids;
    push @pids => $self->{+CURRENT}{pid} if $self->{+CURRENT};

    # Add any registered workers.
    if ($self->can('workers')) {
        push @pids => map { $_->{pid} } values %{$self->workers // {}};
    }

    if (@pids) {
        # TERM all tracked pids. The collector's own cleanup kills its test.
        kill 'TERM', $_ for @pids;

        my $deadline = time + $timeout;
        while (time < $deadline) {
            my @alive = grep { kill(0, $_) } @pids;
            last unless @alive;
            while ((my $p = waitpid(-1, WNOHANG)) > 0) { }
            select undef, undef, undef, 0.05;
        }

        # KILL anything still alive.
        my @alive = grep { kill(0, $_) } @pids;
        if (@alive) {
            kill 'KILL', $_ for @alive;
            # Block-reap.
            waitpid($_, 0) for @alive;
        }

        # Drain any remaining zombies.
        while ((my $p = waitpid(-1, WNOHANG)) > 0) { }
    }

    delete $self->{+CURRENT};
}

sub run_on_all {
    my ($self, $activity) = @_;

    $self->_check_current_completion;

    return if $self->{+CURRENT};
    return if $self->{+STATE} eq 'terminating';
    return unless @{$self->{+QUEUE}};

    my $run = $self->{+QUEUE}[0];
    return unless @{$run->pending};

    my $jid = $run->pending->[0];
    my ($job) = grep { $_->job_id eq $jid } @{$run->jobs};

    my $run_id  = $run->run_id;
    my $log_dir = join '/', $self->{+WORKDIR}, 'runs', $run_id, $jid;
    make_path($log_dir);
    my $log_file = "$log_dir/0.jsonl";

    my $handle = Test2::Harness2::Collector->spawn(
        launch      => [$^X, '-Ilib', $job->test_file],
        new_pgroup  => 1,
        parent_pids => [$$],
        env_vars    => {T2_FORMATTER => 'Stream2'},
        auditor     => [
            $self->{+TEST_AUDITOR},
            run_id => $run_id, job_id => $jid, job_try => 0
        ],
        loggers => [
            [$self->{+TEST_LOGGERS}[0], output_file => $log_file],
        ],
    );

    $run->mark_running($jid);

    $self->{+CURRENT} = {
        run        => $run,
        job        => $job,
        handle     => $handle,
        pid        => $handle->{pid},
        started_at => time,
    };

    $self->register_worker("test-$jid", $handle->{pid})
        if $self->can('register_worker');
}

1;

__END__

=head1 NAME

Test2::Harness2 - Top-level test harness service.

=head1 SYNOPSIS

    # Run once, then exit
    Test2::Harness2->start(
        workdir                  => '/path/to/wd',
        test_run                 => {files => ['t/a.t', 't/b.t']},
        finish_after_initial_run => 1,
    );

    # Spawn as a persistent daemon, keep queuing
    my $spawn = Test2::Harness2->spawn(workdir => '/path/to/wd');
    $spawn->queue_test_run(files => ['t/c.t']);
    my $status = $spawn->status;
    $spawn->finish;
    $spawn->wait;

=head1 DESCRIPTION

B<Use start() or spawn(), not new().> Direct C<new()> constructs the object
but does not start the service loop. Prefer the C<start()> entry point when
you want the current process to become the harness, or C<spawn()> when you
want the harness to run in a child process and get back a handle to it.

=cut
