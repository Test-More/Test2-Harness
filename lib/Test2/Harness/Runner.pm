package Test2::Harness::Runner;
use strict;
use warnings;

our $VERSION = '0.001100';

use File::Spec();

use Carp qw/confess croak/;
use Fcntl qw/LOCK_EX LOCK_UN LOCK_NB/;
use Long::Jump qw/setjump longjump/;
use Time::HiRes qw/sleep time/;

use Test2::Harness::Util qw/clean_path file2mod mod2file open_file parse_exit write_file_atomic/;
use Test2::Harness::Util::Queue();

use Test2::Harness::Runner::Constants;

use Test2::Harness::Runner::Run();
use Test2::Harness::Runner::Job();
use Test2::Harness::Runner::State();
use Test2::Harness::Runner::Preload();
use Test2::Harness::Runner::Preloader();
use Test2::Harness::Runner::Preloader::Stage();
use Test2::Harness::Runner::DepTracer();

use parent 'Test2::Harness::IPC';
use Test2::Harness::Util::HashBase(
    # Fields from settings
    qw{
        <job_count

        <includes <tlib <lib <blib
        <unsafe_inc

        <use_fork <preloads <switches

        <cover

        <event_timeout <post_exit_timeout
    },
    # From Construction
    qw{
        <dir <settings <fork_job_callback <respawn_runner_callback <monitor_preloads
    },
    # Other
    qw {
        <preloader
        <stage
        <signal
        <pending

        +last_timeout_check

        +run +runs +runs_ended +run_queue

        +state

        +dispatch_queue
        +dispatch_lock_file
    },
);

sub job_class  { 'Test2::Harness::Runner::Job' }

sub init {
    my $self = shift;

    croak "'dir' is a required attribute"      unless $self->{+DIR};
    croak "'settings' is a required attribute" unless $self->{+SETTINGS};

    my $dir = clean_path($self->{+DIR});

    croak "'$dir' is not a valid directory"
        unless -d $dir;

    $self->{+PRELOADER} //= Test2::Harness::Runner::Preloader->new(
        dir      => $dir,
        preloads => $self->preloads,
        monitor  => $self->{+MONITOR_PRELOADS},
    );

    $self->{+DIR} = $dir;

    $self->{+JOB_COUNT} //= 1;

    $self->{+PENDING} //= [];

    $self->{+HANDLERS}->{HUP} = sub {
        my $sig = shift;
        print STDERR "$$ ($self->{+STAGE}) Runner caught SIG$sig, reloading...\n";
        $self->{+SIGNAL} = $sig;
    };

    $self->SUPER::init();
}

sub check_timeouts {
    my $self = shift;

    my $now = time;

    # Check only once per second, that is as granular as we get. Also the check is not cheep.
    return if $self->{+LAST_TIMEOUT_CHECK} && $now < (1 + $self->{+LAST_TIMEOUT_CHECK});

    for my $pid (keys %{$self->{+PROCS}}) {
        my $job = $self->{+PROCS}->{$pid};

        my $et  = $job->event_timeout     // $self->{+EVENT_TIMEOUT};
        my $pet = $job->post_exit_timeout // $self->{+POST_EXIT_TIMEOUT};

        next unless $et || $pet;

        my $changed = $job->output_changed();
        my $delta   = $now - $changed;

        # Event timout if we are checking for one, and if the delta is larger than the timeout.
        my $e_to = $et && $delta > $et;

        # Post-Exit timeout if we are checking for one, the process has exited (we are waiting) and the delta is larger than the timeout.
        my $pe_to = $pet && $self->{+WAITING}->{$pid} && $delta > $pet;

        next unless $e_to || $pe_to;

        my $kill = -f $job->et_file || -f $job->pet_file;

        write_file_atomic($job->et_file,  $now) if $e_to  && !-f $job->et_file;
        write_file_atomic($job->pet_file, $now) if $pe_to && !-f $job->pet_file;

        my $sig = $kill ? 'KILL' : 'TERM';
        $sig = "-$sig" if $self->USE_P_GROUPS;

        print STDERR $job->file . " did not respond to SIGTERM, sending SIGKILL to $pid...\n" if $kill;

        kill($sig, $pid);
    }

    $self->{+LAST_TIMEOUT_CHECK} = time;
}

sub stop {
    my $self = shift;

    $self->check_for_fork;

    if (keys %{$self->{+PROCS}}) {
        print "Sending all child processes the TERM signal...\n";
        # Send out the TERM signal
        $self->killall($self->{+SIGNAL} // 'TERM');
        $self->wait(all => 1, timeout => 5);
    }

    # Time to get serious
    if (keys %{$self->{+PROCS}}) {
        print STDERR "Some child processes are refusing to exit, sending KILL signal...\n";
        $self->killall('KILL');
    }

    $self->SUPER::stop();
}

sub dispatch_lock_file {
    my $self = shift;
    return $self->{+DISPATCH_LOCK_FILE} //= File::Spec->catfile($self->{+DIR}, 'DISPATCH_LOCK');
}

sub dispatch_queue {
    my $self = shift;
    $self->{+DISPATCH_QUEUE} //= Test2::Harness::Util::Queue->new(
        file => File::Spec->catfile($self->{+DIR}, "dispatch.jsonl"),
    );
}

sub run_queue {
    my $self = shift;
    return $self->{+RUN_QUEUE} //= Test2::Harness::Util::Queue->new(
        file => File::Spec->catfile($self->{+DIR}, 'run_queue.jsonl'),
    );
}

sub handle_sig {
    my $self = shift;
    my ($sig) = @_;

    return if $self->{+SIGNAL};

    return $self->{+HANDLERS}->{$sig}->($sig) if $self->{+HANDLERS}->{$sig};

    $self->{+SIGNAL} = $sig;
    die "Runner caught SIG$sig. Attempting to shut down cleanly...\n";
}

sub all_libs {
    my $self = shift;

    my @out;
    push @out => clean_path('t/lib') if $self->{+TLIB};
    push @out => clean_path('lib')   if $self->{+LIB};

    if ($self->{+BLIB}) {
        push @out => clean_path('blib/lib');
        push @out => clean_path('blib/arch');
    }

    push @out => map { clean_path($_) } @{$self->{+INCLUDES}} if $self->{+INCLUDES};

    return @out;
}

sub process {
    my $self = shift;

    my %seen;
    @INC = grep { !$seen{$_}++ } $self->all_libs, @INC, $self->unsafe_inc ? ('.') : ();

    my $pidfile = File::Spec->catfile($self->{+DIR}, 'PID');
    write_file_atomic($pidfile, "$$");

    $self->start();

    my $ok  = eval { $self->run_tests(); 1 };
    my $err = $@;

    warn $err unless $ok;

    $self->stop();

    return $self->{+SIGNAL} ? 128 + $self->SIG_MAP->{$self->{+SIGNAL}} : $ok ? 0 : 1;
}

sub run_tests {
    my $self = shift;

    my ($stage, @procs) = $self->{+PRELOADER}->preload();

    $self->watch($_) for @procs;

    while(1) {
        my $jump = setjump "Stage-Runner" => sub {
            $self->run_stage($stage);
        };

        last unless $jump;

        $stage = @$jump;
        $self->_reset_stage();
    }

    return;
}

sub reset_stage {
    my $self = shift;

    # Normalize IPC
    $self->check_for_fork();

    # From Runner
    delete $self->{+STAGE};
    delete $self->{+STATE};
    delete $self->{+PRELOADER};
    delete $self->{+PENDING};
    delete $self->{+LAST_TIMEOUT_CHECK};
    delete $self->{+RUN};
    delete $self->{+RUNS};
    delete $self->{+RUNS_ENDED};
    delete $self->{+RUN_QUEUE};
    delete $self->{+STATE};
    delete $self->{+DISPATCH_QUEUE};
    delete $self->{+DISPATCH_LOCK_FILE};

    return;
}

sub run_stage {
    my $self = shift;
    my ($stage) = @_;

    $self->{+STAGE} = $stage;
    $self->dispatch_queue->enqueue({action => 'mark_stage_ready', arg => $stage, pid => $$, stamp => time});

    $self->{+STATE} = Test2::Harness::Runner::State->new(
        staged    => $self->{+PRELOADER}->staged ? 1 : 0,
        job_count => $self->{+JOB_COUNT},
    );

    while (1) {
        print "stage loop\n";

        next if $self->run_job();

        next if $self->wait(cat => $self->job_class->category);

        last if $self->end_test_loop();

        sleep($self->{+WAIT_TIME}) if $self->{+WAIT_TIME};
    }

    $self->dispatch_queue->enqueue({action => 'mark_stage_down', arg => $stage, pid => $$, stamp => time});
    $self->wait(all => 1);
}

sub run_job {
    my $self = shift;

    my $run = $self->run() or return 0;
    my $task = $self->next() or return 0;

    my $job = $self->job_class->new(
        runner   => $self,
        task     => $task,
        run      => $run,
        settings => $self->settings,
    );

    $job->prepare_dir();

    my $spawn_time;

    my $pid;
    my $via = $job->via;
    $via //= $self->{+FORK_JOB_CALLBACK} if $job->use_fork;
    if ($via) {
        $spawn_time = time();
        $pid        = $self->$via($job);
        $job->set_pid($pid);
        $self->watch($job);
    }
    else {
        $spawn_time = time();
        $self->spawn($job);
    }

    my $json_data = $job->TO_JSON();
    $json_data->{stamp} = $spawn_time;
    $run->jobs->write($json_data);

    return $pid;
}

sub end_test_loop {
    my $self = shift;

    print "A\n";
    $self->{+respawn_runner_callback}->()
        if $self->{+PRELOADER}->check
        || $self->{+SIGNAL} && $self->{+SIGNAL} eq 'HUP';

    print "B\n";
    return 1 if $self->{+SIGNAL};

    print "C\n";
    return 0 unless $self->end_task_loop;

    print "D\n";
    return 0 if @{$self->poll_runs};
    print "E\n";
    return 1 if $self->{+RUNS_ENDED};

    print "F\n";
    return 0;
}

sub queue_ended {
    my $self = shift;
    my $run  = $self->run or return 1;
    return $run->queue_ended;
}

sub run {
    my $self = shift;

    $self->clear_finished_run;

    return $self->{+RUN} if $self->{+RUN};

    my $runs = $self->poll_runs;
    return undef unless @$runs;

    $self->{+RUN} = shift @$runs;
}

sub clear_finished_run {
    my $self = shift;

    $self->poll_dispatch();

    return if @{$self->{+PENDING} //= []};
    return if $self->{+STATE}->todo;
    return if $self->{+STATE}->running;

    return unless $self->{+RUN};
    return unless $self->{+RUN}->queue_ended;

    delete $self->{+RUN};
}

sub poll_runs {
    my $self = shift;

    my $runs = $self->{+RUNS} //= [];

    return $runs if $self->{+RUNS_ENDED};

    my $run_queue = $self->run_queue();

    for my $item ($run_queue->poll()) {
        my $run_data = $item->[-1];

        if (!defined $run_data) {
            $self->{+RUNS_ENDED} = 1;
            last;
        }

        push @$runs => Test2::Harness::Runner::Run->new(
            %$run_data,
            workdir => $self->{+DIR},
        );
    }

    return $runs;
}

sub next {
    my $self = shift;

    my $pending = $self->{+PENDING};

    while (1) {
        $self->poll();
        return shift @$pending if @$pending;

        # Reap any completed PIDs
        next if $self->wait();

        next if $self->manage_dispatch;

        last if $self->end_task_loop();

        sleep($self->{+WAIT_TIME}) if $self->{+WAIT_TIME};
    }

    return undef;
}

sub end_task_loop {
    my $self = shift;

    $self->poll_dispatch();

    return 0 if @{$self->{+PENDING} //= []};
    return 0 if $self->{+STATE}->todo;
    return 0 if $self->{+STATE}->running;
    return 0 if $self->run;
    return 1 if $self->queue_ended;

    return 0;
}

sub poll {
    my $self = shift;

    $self->poll_dispatch();

    # This will poll runs for us.
    return unless $self->run;

    $self->poll_tasks();
}

sub poll_tasks {
    my $self = shift;

    return if $self->queue_ended;

    my $run   = $self->run or return;
    my $queue = $run->queue;

    my $added = 0;
    for my $item ($queue->poll) {
        my ($spos, $epos, $task) = @$item;

        $added++;

        if (!$task) {
            $run->set_queue_ended(1);
            last;
        }

        my $cat = $task->{category};
        $cat = 'general' unless $cat && CATEGORIES->{$cat};
        $task->{category} = $cat;

        my $dur = $task->{duration};
        $dur = 'medium' unless $dur && DURATIONS->{$dur};
        $task->{duration} = $dur;

        $task->{stage} = $self->task_stage($task);

        $self->add_task($task);
    }

    return $added;
}

sub task_stage {
    my $self = shift;
    my ($task) = @_;

    my $stage = $task->{stage};
    $stage = 'default' unless $stage && $self->{+PRELOADER}->stage_check($stage);

    return $stage;
}

sub add_task {
    my $self = shift;
    my ($task) = @_;

    $self->{+STATE}->add_pending_task($task);
}

my %ACTIONS = (dispatch => 1, complete => 1, mark_stage_ready => 1, mark_stage_down => 1, retry => 1);
sub poll_dispatch {
    my $self = shift;
    my $queue = $self->dispatch_queue;
    for my $item ($queue->poll) {
        my $data = $item->[-1];
        my $arg = $data->{arg};
        my $action = $data->{action};

        die "Invalid action '$action'" unless $ACTIONS{$action};

        $self->$action($arg);
    }
}

sub dispatch {
    my $self = shift;
    my ($task) = @_;

    $self->{+STATE}->start_task($task);
    push @{$self->{+PENDING}} => $task if $task->{stage} eq $self->{+STAGE};
}

sub retry {
    my $self = shift;
    my ($task) = @_;

    $task = { %$task, category => 'isolation' } if $self->run->retry_isolated;

    $self->{+STATE}->stop_task($task);
    $self->{+STATE}->add_pending_task($task);
}

sub mark_stage_ready {
    my $self = shift;
    my ($stage) = @_;

    $self->{+STATE}->mark_stage_ready($stage);
}

sub mark_stage_down {
    my $self = shift;
    my ($stage) = @_;

    $self->{+STATE}->mark_stage_down($stage);
}

sub complete {
    my $self = shift;
    my ($task) = @_;
    $self->{+STATE}->stop_task($task);
}

sub manage_dispatch {
    my $self = shift;

    # Do not bother with the lock if we are not staged
    unless ($self->{+PRELOADER}->staged) {
        $self->dispatch_loop;
        return 1;
    }

    my $lock = open_file($self->dispatch_lock_file, '>>');
    flock($lock, LOCK_EX | LOCK_NB) or return 0;
    seek($lock,2,0);

    my $ok = eval { $self->dispatch_loop; 1 };
    my $err = $@;

    # Unlock
    $lock->flush;
    flock($lock, LOCK_UN) or warn "Could not unlock dispatch: $!";
    close($lock);

    die $err unless $ok;

    return 1;
}

sub dispatch_loop {
    my $self = shift;

    while (1) {
        $self->poll;

        $self->do_dispatch();

        last if @{$self->{+PENDING}};

        next if $self->wait();

        last if $self->end_task_loop;

        sleep $self->{+WAIT_TIME} if $self->{+WAIT_TIME};
    }
}

sub do_dispatch {
    my $self = shift;

    my $task = $self->{+STATE}->pick_task() or return;
    $self->dispatch_queue->enqueue({action => 'dispatch', arg => $task, pid => $$, stamp => time});

    return;
}

sub set_proc_exit {
    my $self = shift;
    my ($proc, $exit, $time, @args) = @_;

    if ($proc->isa('Test2::Harness::Runner::Job')) {
        my $task = $proc->task;

        if ($exit && $proc->is_try < $proc->retry) {
            $task = {%$task};    # Clone
            $task->{is_try}++;
            $self->retry_task($task);
            push @args => 'will-retry';
        }
        else {
            $self->completed_task($task);
        }
    }
    elsif ($proc->isa('Test2::Harness::Runner::Preloader::Stage')) {
        my $stage = $proc->name;

        if ($exit != 0) {
            my $e = parse_exit($exit);
            warn "Child stage '$stage' did not exit cleanly (sig: $e->{sig}, err: $e->{err})!\n";
        }

        unless ($self->end_task_loop) {
            my $proc = $self->preloader->launch_stage($stage, $exit);
            longjump "Stage-Runner" => $stage unless $proc;
            $self->watch($proc);
        }
    }

    $self->SUPER::set_proc_exit($proc, $exit, $time, @args);
}

sub retry_task {
    my $self = shift;
    my ($task) = @_;

    $self->dispatch_queue->enqueue({action => 'retry', arg => $task, pid => $$, stamp => time});
}

sub completed_task {
    my $self = shift;
    my ($task) = @_;
    $self->dispatch_queue->enqueue({action => 'complete', arg => $task, pid => $$, stamp => time});
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner - Base class for test runners

=head1 DESCRIPTION

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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
