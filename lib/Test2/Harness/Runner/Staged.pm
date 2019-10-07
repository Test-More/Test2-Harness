package Test2::Harness::Runner::Staged;
use strict;
use warnings;

our $VERSION = '0.001100';

use Carp qw/confess/;
use Fcntl qw/LOCK_EX LOCK_UN LOCK_NB/;
use Time::HiRes qw/sleep time/;
use Test2::Harness::Util qw/write_file_atomic open_file parse_exit file2mod/;
use Long::Jump qw/setjump longjump/;

use File::Spec();

use Test2::Harness::Util::Queue();
use Test2::Harness::Runner::Preload();
use Test2::Harness::Runner::DepTracer();
use Test2::Harness::Runner::Run();
use Test2::Harness::Runner::Staged::Stage();
use Test2::Harness::Runner::State();

use parent 'Test2::Harness::Runner';
use Test2::Harness::Util::HashBase qw{
    -stage

    <pending
    +run +runs +runs_ended

    +state

    +dispatch_queue
    +dispatch_lock_file
};

sub dispatch_lock_file {
    my $self = shift;
    return $self->{+DISPATCH_LOCK_FILE} //= File::Spec->catfile($self->{+DIR}, 'DISPATCH_LOCK');
}

sub init {
    my $self = shift;

    $self->SUPER::init();

    delete $self->{+STAGE};

    $self->{+PENDING} //= [];

    $self->{+STATE} //= Test2::Harness::Runner::State->new(
        staged    => 1,
        job_count => $self->{+JOB_COUNT},
    );

    $self->{+HANDLERS}->{HUP} = sub {
        my $sig = shift;
        print STDERR "$$ ($self->{+STAGE}) Runner caught SIG$sig, reloading...\n";
        $self->{+SIGNAL} = $sig;
    };
}

sub respawn {
    my $self = shift;

    print "$$ ($self->{+STAGE}) Waiting for currently running jobs to complete before respawning...\n";
    $self->killall('HUP');
    $self->wait(all => 1);

    my $settings = $self->settings;

    exec(
        $^X,
        $settings->yath->script,
        (map { "-D$_" } @{$settings->yath->dev_libs}),
        'runner',
        ref($self),
        $self->{+DIR},
    );

    warn "Should not get here, respawn failed";
    CORE::exit(1);
}

sub run_tests {
    my $self = shift;

    my $wait_time = $self->{+WAIT_TIME};

    my $stage = $self->{+STAGES}->[0];
    my $spawn = $self->stage_spawn_map();

    my $ok = eval { $self->spawn_stage($stage, $spawn); 1 };
    my $err = $@;

    warn $ok ? "Should never get here, spawn_stage() is not supposed to return" : $err;
    CORE::exit(1);
}

sub stage_spawn_map {
    my $self = shift;

    my %spawn;
    my ($root, @children) = @{$self->{+STAGES}};

    my $parent = $root;
    for my $stage (@children) {
        push @{$spawn{$parent}} => $stage;
        $parent = $stage unless $self->SUPER::stage_should_fork($stage);
    }

    return \%spawn;
}

sub spawn_child_stages {
    my $self = shift;
    my ($list) = @_;
    return unless $list;

    for my $stage (@$list) {
        my $pid = fork;
        unless (defined($pid)) {
            warn "Failed to fork";
            CORE::exit(1);
        }

        # Child;
        return $stage unless $pid;

        my $proc = Test2::Harness::Runner::Staged::Stage->new(pid => $pid, name => $stage);
        $self->watch($proc);
    }

    return undef;
}

sub spawn_stage_callback {
    my $self = shift;
    my ($spawn) = @_;

    my $new_stage;
    my $spawn_meth = $self->can('spawn_stage');

    my $do_spawn = sub {
        $self->dtrace->clear_loaded;
        @_ = ($self, $new_stage, $spawn);
        goto &$spawn_meth;
    };

    return (\$new_stage, $do_spawn);
}

sub spawn_stage {
    my $self = shift;
    my ($stage, $spawn) = @_;

    $self->stage_start($stage);

    # If we get 'new_stage' then we are in a child process and need to load the new stage
    my ($new_stage, $spawn_stage) = $self->spawn_stage_callback($spawn);
    goto &$spawn_stage if $$new_stage = $self->spawn_child_stages($spawn->{$stage});

    $self->monitor();

    $self->dispatch_queue->enqueue({action => 'mark_stage_ready', arg => $stage});

    print "$$ ($self->{+STAGE}) Ready to run tests...\n";

    my ($ok, $err);
    my $jump = setjump 'Test-Runner-Stage' => sub {
        $ok = eval { $self->task_loop($stage); 1 };
        $err = $@;
    };

    $self->check_for_fork();

    # If we are here than a shild stage exited cleanly and we are already in a
    # child stage and need to swap to it.
    goto &$spawn_stage if $jump && ($$new_stage = $jump->[0]);

    $self->stage_exit($stage, $ok, $err);
}

sub stage_start {
    my $self = shift;
    my ($stage) = @_;

    $0 = "yath-runner-$stage";
    $self->{+STAGE} = $stage;
    $self->load_blacklist;

    my $dtrace = $self->dtrace;
    $dtrace->start;

    my $start_meth = "start_stage_$stage";
    for my $mod (@{$self->{+STAGED}}) {
        # Localize these in case something we preload tries to modify them.
        local $SIG{INT}  = $SIG{INT};
        local $SIG{HUP}  = $SIG{HUP};
        local $SIG{TERM} = $SIG{TERM};

        next unless $mod->can($start_meth);
        $mod->$start_meth;
    }

    $dtrace->stop;

    return;
}

sub stage_exit {
    my $self = shift;
    my ($stage, $ok, $err) = @_;

    print "$$ ($self->{+STAGE}) Waiting for jobs and child stages to complete before exiting...\n";
    $self->wait(all => 1);

    if ($ok && $stage eq $self->{+STAGES}->[0] && $self->{+SIGNAL} && $self->{+SIGNAL} eq 'HUP') {
        $self->respawn;
        warn "Should never get here, respawn failed";
        CORE::exit(1);
    }

    my $sig = $self->{+SIGNAL};
    CORE::exit($self->sig_exit_code($sig)) if $sig && $sig !~ m/^(SIG)?HUP$/i;
    CORE::exit(0) if $ok;

    warn $err;
    CORE::exit(1);
}

sub set_proc_exit {
    my $self = shift;
    my ($proc, $exit, $time, @args) = @_;

    $self->SUPER::set_proc_exit($proc, $exit, $time, @args);

    return unless $proc->isa('Test2::Harness::Runner::Staged::Stage');

    my $stage = $proc->name;

    if ($exit != 0) {
        my $e = parse_exit($exit);
        warn "Child stage '$stage' did not exit cleanly (sig: $e->{sig}, err: $e->{err})!\n";
        CORE::exit(1);
    }

    return if $self->all_done;

    my $pid = fork;
    unless (defined($pid)) {
        warn "Failed to fork";
        CORE::exit(1);
    }

    # Add the replacement process to the watch list
    if ($pid) {
        $self->watch(Test2::Harness::Runner::Staged::Stage->new(pid => $pid, name => $stage));
        return;
    }

    # In the child we do the long jump to unwind the stack
    longjump 'Test-Runner-Stage' => $stage;

    warn "Should never get here, failed to restart stage '$stage'";
    CORE::exit(1);
}

sub task_loop {
    my $self = shift;

    while(my $task = $self->next) {
        $self->run_job($self->run, $task);
    }
}

sub next {
    my $self = shift;

    my $pending = $self->{+PENDING};

    while (1) {
        $self->poll();
        return shift @$pending if @$pending;

        next if $self->wait();

        return if $self->all_done();

        next if $self->manage_dispatch;

        sleep $self->{+WAIT_TIME} if $self->{+WAIT_TIME};
    }
}

sub all_done {
    my $self = shift;

    $self->check_monitored;

    return 1 if $self->{+SIGNAL};

    return 0 if @{$self->{+PENDING} //= []};

    return 0 if $self->{+STATE}->todo;

    return 0 if $self->run;
    return 0 if @{$self->poll_runs};

    return 1 if $self->{+RUNS_ENDED};
    return 0;
}

sub poll {
    my $self = shift;

    # This will poll runs for us.
    return unless $self->run;

    $self->poll_tasks();
    $self->poll_dispatch();
}

sub poll_runs {
    my $self = shift;

    my $runs = $self->{+RUNS} //= [];

    return $runs if $self->{+RUNS_ENDED};

    my $run_queue = Test2::Harness::Util::Queue->new(file => File::Spec->catfile($self->{+DIR}, 'run_queue.jsonl'));

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

sub clear_finished_run {
    my $self = shift;

    return unless $self->{+RUN};
    return unless $self->{+RUN}->queue_ended;

    return if @{$self->{+PENDING} //= []};
    return if $self->{+STATE}->todo;

    delete $self->{+RUN};
}

sub run {
    my $self = shift;

    $self->clear_finished_run;

    return $self->{+RUN} if $self->{+RUN};

    my $runs = $self->poll_runs;
    return undef unless @$runs;

    die "Previous run is not done!" if $self->{+STATE}->todo;

    $self->{+RUN} = shift @$runs;
}

sub retry_task {
    my $self = shift;
    my ($task) = @_;

    unshift @{$self->{+PENDING}} => $task;
}

sub completed_task {
    my $self = shift;
    my ($task) = @_;
    $self->dispatch_queue->enqueue({action => 'complete', arg => $task});
}

sub dispatch_queue {
    my $self = shift;
    $self->{+DISPATCH_QUEUE} //= Test2::Harness::Util::Queue->new(
        file => File::Spec->catfile($self->{+DIR}, "dispatch.jsonl"),
    );
}

my %ACTIONS = (dispatch => 1, complete => 1, mark_stage_ready => 1);
sub poll_dispatch {
    my $self = shift;
    my $queue = $self->dispatch_queue;
    for my $item ($queue->poll) {
        my $data = $item->[-1];
        my $arg = $data->{arg};
        my $action = $data->{action};

        use Data::Dumper;
        print Dumper([$action, $arg]);

        die "Invalid action '$action'" unless $ACTIONS{$action};

        $self->$action($arg);
    }
}

sub mark_stage_ready {
    my $self = shift;
    my ($stage) = @_;

    $self->{+STATE}->mark_stage_ready($stage);
}

sub dispatch {
    my $self = shift;
    my ($task) = @_;

    $self->{+STATE}->start_task($task);
    push @{$self->{+PENDING}} => $task if $task->{stage} eq $self->{+STAGE};
}

sub add_task {
    my $self = shift;
    my ($task) = @_;

    $self->{+STATE}->add_pending_task($task);
}

sub complete {
    my $self = shift;
    my ($task) = @_;
    $self->{+STATE}->stop_task($task);
}

sub manage_dispatch {
    my $self = shift;

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

        next if $self->wait();

        last if @{$self->{+PENDING}};

        last if $self->all_done();

        sleep $self->{+WAIT_TIME} if $self->{+WAIT_TIME};
    }
}

sub do_dispatch {
    my $self = shift;

    my $task = $self->{+STATE}->pick_task() or return;
    $self->dispatch_queue->enqueue({action => 'dispatch', arg => $task});
    return $task;
}

sub task_stage {
    my $self = shift;
    my ($task) = @_;

    my $stage = $task->{stage};
    $stage = 'default' unless $stage && $self->{+PRELOADS}->stage_check($stage);

    return $stage;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Staged - Runner that loads all stages concurrently.

=head1 DESCRIPTION

B<PLEASE NOTE:> Test2::Harness is still experimental, it can all change at any
time. Documentation and tests have not been written yet!

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
