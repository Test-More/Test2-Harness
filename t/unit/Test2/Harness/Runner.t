use Test2::V0;

__END__

package Test2::Harness::Runner;
use strict;
use warnings;

our $VERSION = '0.001100';

use POSIX;
use File::Spec();

use Carp qw/croak confess/;
use Fcntl qw/LOCK_EX LOCK_UN LOCK_NB/;
use Config qw/%Config/;
use List::Util qw/none first/;
use Time::HiRes qw/sleep time/;
use Test2::Util qw/CAN_REALLY_FORK/;

use Test2::Harness::Util qw/clean_path mod2file write_file_atomic read_file/;
use Test2::Harness::Util::JSON qw/decode_json/;
use Test2::Harness::Util::Queue;

use Test2::Harness::Runner::Run();
use Test2::Harness::Runner::Job();

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
    # Other fields
    qw{
        <dir <settings <fork_job_callback

        <signal

        <staged <stages <stage_check <fork_stages

        <initialized_preloads

        +queue
        +run
        +preload_done

        +pending +grouped +todo

        +lock -lock_file

        +state_cache

        +event_timeout_last
        +post_exit_timeout_last
    },
);

my %CATEGORIES = (
    general    => 1,
    isolation  => 1,
    immiscible => 1,
);

my %DURATIONS = (
    long   => 1,
    medium => 1,
    short  => 1,
);

sub finite { 1 }

#<<< no-tidy
sub grouped { $_[0]->{+GROUPED}->{$_[1]->run_id}->{$_[2]} //= {} }
sub pending { $_[0]->{+PENDING}->{$_[1]->run_id}->{$_[2]} //= [] }
sub todo    { $_[0]->{+TODO   }->{$_[1]->run_id}->{$_[2]} //= do { my $todo = 0; \$todo } }
#>>>

sub init {
    my $self = shift;

    croak "'dir' is a required attribute" unless $self->{+DIR};
    croak "'settings' is a required attribute" unless $self->{+SETTINGS};

    my $dir = clean_path($self->{+DIR});

    croak "'$dir' is not a valid directory"
        unless -d $dir;

    $self->{+DIR} = $dir;

    $self->{+STAGES}      = ['default'];
    $self->{+STAGE_CHECK} = { map {($_ => 1)} @{$self->{+STAGES}} };

    $self->{+STAGED}      = [];
    $self->{+FORK_STAGES} = {};

    $self->{+JOB_COUNT} //= 1;

    $self->{+EVENT_TIMEOUT_LAST}     = time;
    $self->{+POST_EXIT_TIMEOUT_LAST} = time;

    $self->SUPER::init();
}

sub process {
    my $self = shift;

    my %seen;
    @INC = grep { !$seen{$_}++ } $self->all_libs, @INC, $self->unsafe_inc ? ('.') : ();

    my $pidfile = File::Spec->catfile($self->{+DIR}, 'PID');
    write_file_atomic($pidfile, "$$");

    $self->start();

    $self->preload;

    my $ok  = eval { $self->stage_loop(); 1 };
    my $err = $@;

    warn $err unless $ok;

    $self->write_remaining_exits;

    $self->stop();

    return $self->{+SIGNAL} ? 128 + $self->SIG_MAP->{$self->{+SIGNAL}} : $ok ? 0 : 1;
}

sub handle_sig {
    my $self = shift;
    my ($sig) = @_;

    return if $self->{+SIGNAL};

    $self->{+SIGNAL} = $sig;

    return $self->{+HANDLERS}->{$sig}->($sig) if $self->{+HANDLERS}->{$sig};

    die "Runner caught SIG$sig. Attempting to shut down cleanly...\n";
}

sub all_libs {
    my $self = shift;

    my @out;
    push @out => clean_path('t/lib') if $self->{+TLIB};
    push @out => clean_path('lib') if $self->{+LIB};

    if ($self->{+BLIB}) {
        push @out => clean_path('blib/lib');
        push @out => clean_path('blib/arch');
    }

    push @out => map { clean_path($_) } @{$self->{+INCLUDES}} if $self->{+INCLUDES};

    return @out;
}

sub preload {
    my $self = shift;

    return if $self->{+PRELOAD_DONE};
    $self->{+PRELOAD_DONE} = 1;

    my $preloads = $self->{+PRELOADS} or return;
    return unless @$preloads;

    require Test2::API;
    Test2::API::test2_start_preload();

    $self->_preload($preloads);
}

sub _preload {
    my $self = shift;
    my ($preloads, $block, $require_sub) = @_;

    return unless $preloads && @$preloads;

    $block //= {};

    my %seen = map { ($_ => 1) } @{$self->{+STAGES}};

    for my $mod (@$preloads) {
        next if $block && $block->{$mod};

        $self->_preload_module($mod, $block, $require_sub);
    }
}

sub _preload_module {
    my $self = shift;
    my ($mod, $block, $require_sub) = @_;

    my $file = mod2file($mod);

    $require_sub ? $require_sub->($file) : require $file;

    return unless $mod->isa('Test2::Harness::Preload');

    my %args = (
        finite => $self->finite,
        block  => $block,
    );

    my $imod = $self->_preload_module_init($mod, %args);
    push @{$self->{+STAGED}} => $imod;

    $self->{+FORK_STAGES}->{$_} = 1 for $imod->fork_stages;

    my %seen;
    my $stages = $self->{+STAGES};
    my $idx = 0;
    for my $stage ($imod->stages) {
        unless ($seen{$stage}++) {
            splice(@$stages, $idx++, 0, $stage);
            next;
        }

        for (my $i = $idx; $i < @$stages; $i++) {
            next unless $stages->[$i] eq $stage;
            $idx = $i + 1;
            last;
        }
    }
}

sub _preload_module_init {
    my $self = shift;
    my ($mod, %args) = @_;

    return $mod->new(%args) if $mod->can('new');

    $mod->preload(%args);
    return $mod;
}

sub stage_should_fork {
    my $self = shift;
    my ($stage) = @_;
    return $self->{+FORK_STAGES}->{$stage} || 0;
}

sub stage_fork {
    my $self = shift;
    my ($stage) = @_;

    # Must do this before we can fork
    $self->wait(all_cat => Test2::Harness::Runner::Job->category);

    my $pid = fork();
    die "Could not fork" unless defined $pid;

    # Child returns true
    unless ($pid) {
        $0 = 'yath-runner-' . $stage;
        return 1;
    }

    # Parent waits for child
    my $check = waitpid($pid, 0);
    my $ret = $?;

    die "waitpid returned $check" unless $check == $pid;
    die "Child process did not exit cleanly: $ret" if $ret;

    return 0;
}

sub stage_start {
    my $self = shift;
    my ($stage) = @_;

    my $fork = $self->stage_should_fork($stage);

    return 0 if $fork && !$self->stage_fork($stage);

    my $start_meth = "start_stage_$stage";
    for my $mod (@{$self->{+STAGED}}) {
        # Localize these in case something we preload tries to modify them.
        local $SIG{INT}  = $SIG{INT};
        local $SIG{HUP}  = $SIG{HUP};
        local $SIG{TERM} = $SIG{TERM};

        next unless $mod->can($start_meth);
        $mod->$start_meth;
    }

    return 1;
}

sub stage_stop {
    my $self = shift;
    my ($stage) = @_;

    return unless $self->stage_should_fork($stage);

    $self->wait(all_cat => Test2::Harness::Runner::Job->category);

    CORE::exit(0);
}

sub stage_loop {
    my $self = shift;

    my $run = $self->run(); # Find the run pre-fork since we are not a persistent runner

    for my $stage (@{$self->{+STAGES}}) {
        $self->stage_start($stage) or next;

        $self->task_loop($stage);

        $self->stage_stop($stage);
    }

    $self->wait(all => 1);
}

sub run {
    my $self = shift;
    my ($stage) = @_;

    return $self->{+RUN} if $self->{+RUN};

    my $run_queue = Test2::Harness::Util::Queue->new(file => File::Spec->catfile($self->{+DIR}, 'run_queue.jsonl'));
    my @runs = $run_queue->poll();

    confess "More than 1 run was found in the queue for a non-persistent runner"
        if @runs != 2 || defined($runs[1]->[-1]) || !$run_queue->ended;

    return $self->{+RUN} = Test2::Harness::Runner::Run->new(
        %{$runs[0]->[-1]},
        workdir => $self->{+DIR},
    );
}

sub task_loop {
    my $self = shift;
    my ($stage) = @_;

    my $run = $self->run($stage);

    while (1) {
        my $task = $self->next($run, $stage) or last;
        $self->run_job($run, $task);
    };
}

sub run_job {
    my $self = shift;
    my ($run, $task) = @_;

    my $job = Test2::Harness::Runner::Job->new(
        runner   => $self,
        task     => $task,
        run      => $run,
        settings => $self->settings,
    );

    $job->prepare_dir();

    my $pid;
    my $via = $job->via;
    $via //= $self->{+FORK_JOB_CALLBACK} if $job->use_fork;
    if ($via) {
        $pid = $self->$via($job);
        $job->set_pid($pid);
        $self->watch($job);
    }
    else {
        $self->spawn($job);
    }

    $run->jobs->write($job);

    delete $self->{+STATE_CACHE};

    return $pid;
}

sub next {
    my $self = shift;
    my ($run, $stage) = @_;

    # Get a new task to run.
    my $task = $self->_next($run, $stage);

    # If there are no more tasks then wait on the remaining jobs to complete.
    $self->wait(all_cat => Test2::Harness::Runner::Job->category) unless $task;

    # Return task or undef if we're done.
    return $task;
}

sub check_timeouts {
    my $self = shift;

    my $now = time;

    my $check_ev = $self->{+EVENT_TIMEOUT}     && $now >= ($self->{+EVENT_TIMEOUT_LAST} + $self->{+EVENT_TIMEOUT});
    my $check_pe = $self->{+POST_EXIT_TIMEOUT} && $now >= ($self->{+POST_EXIT_TIMEOUT_LAST} + $self->{+POST_EXIT_TIMEOUT});

    return unless $check_ev || $check_pe;

    $self->{+EVENT_TIMEOUT_LAST}     = time;
    $self->{+POST_EXIT_TIMEOUT_LAST} = time;

    for my $pid (keys %{$self->{+PROCS}}) {
        my $job       = $self->{+PROCS}->{$pid};
        my $last_size = $job->last_output_size;
        my $new_size  = $job->output_size;

        # If last_size is undefined then we have never checked this job, so it
        # started since the last loop, do not time it out yet.
        next unless defined $last_size;

        print "$pid:\n  $new_size\n  $last_size\n";
        next if $new_size > $last_size;

        my $kill = -f $job->et_file || -f $job->pet_file;

        print "$pid: Timing out job " . $job->file . "\n";
        write_file_atomic($job->et_file,  $now) if $check_ev && !-f $job->et_file;
        write_file_atomic($job->pet_file, $now) if $check_pe && !-f $job->pet_file;

        my $sig = $kill ? 'KILL' : 'TERM';
        $sig = "-$sig" if $self->USE_P_GROUPS;
        kill($sig, $pid);
    }
}

sub wait {
    my $self = shift;
    my %params = @_;

    my $found = $self->SUPER::wait(%params);

    $self->unlock unless keys %{$self->{+PROCS}};
    delete $self->{+STATE_CACHE} if $found;

    return $found;
}

sub lock {
    my $self = shift;
    return 1 if $self->{+LOCK};
    return 1 unless $self->{+LOCK_FILE};

    open(my $lock, '>>', $self->{+LOCK_FILE}) or die "Could not open lock file: $!";
    flock($lock, LOCK_EX | LOCK_NB) or return 0;
    $self->{+LOCK} = $lock;

    return 1;
}

sub unlock {
    my $self = shift;

    my $lock = delete $self->{+LOCK} or return 1;
    flock($lock, LOCK_UN);
    close($lock);
    return 1;
}

sub end_loop { 0 }

sub _next {
    my $self = shift;
    my ($run, $stage) = @_;

    my $todo = $self->todo($run, $stage);
    my $list = $self->pending($run, $stage);

    my $max = $self->{+JOB_COUNT};

    my $next_meth = $max <= 1 ? '_next_simple' : '_next_concurrent';

    my $iter = 0;
    while (@$list || $$todo || !$run->queue_ended) {
        return if $self->end_loop;

        my $task = $self->_next_iter($run, $stage, $iter++, $max, $next_meth);

        return $task if $task;
    }

    return;
}

sub _next_iter {
    my $self = shift;
    my ($run, $stage, $iter, $max, $next_meth) = @_;

    sleep($self->{+WAIT_TIME}) if $iter && $self->{+WAIT_TIME};

    # Check the job files for active and newly kicked off tasks.
    # Updates $list which we use to decide if we need to keep looping.
    $self->poll_tasks($run);

    # Reap any completed PIDs
    $self->wait();

    if ($self->{+LOCK_FILE}) {
        my $todo = ${$self->todo($run, $stage)} || @{$self->pending($run, $stage)};

        unless ($todo) {
            $self->unlock;
            return;
        }

        # Make sure we have the lock
        return unless $self->lock;
    }

    # No new jobs yet to kick off yet because too many are running.
    return if keys(%{$self->{+PROCS}}) >= $max;

    my $task = $self->$next_meth($run, $stage) or return;
    return $task;
}

sub poll_tasks {
    my $self = shift;
    my ($run) = @_;

    return if $run->queue_ended;

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
        $cat = 'general' unless $cat && $CATEGORIES{$cat};
        $task->{category} = $cat;

        my $dur = $task->{duration};
        $dur = 'medium' unless $dur && $DURATIONS{$dur};
        $task->{duration} = $dur;

        my $stage = $task->{stage};
        $stage = 'default' unless $stage && $self->{+STAGE_CHECK}->{$stage};
        $task->{stage} = $stage;

        push @{$self->pending($run, $stage)} => $task;
    }

    return $added;
}

sub _next_simple {
    my $self = shift;
    my ($run, $stage) = @_;

    # If we're only allowing 1 job at a time, then just give the
    # next one on the list, unless 1 is running
    return shift @{$self->pending($run, $stage)};
}

sub _running_state {
    my $self = shift;

    return $self->{+STATE_CACHE} if $self->{+STATE_CACHE};

    my $running = 0;
    my %cats;
    my %durs;
    my %active_conflicts;

    for my $job (values %{$self->{+PROCS}}) {
        my $task = $job->task;
        $running++;
        $cats{$task->{category}}++;
        $durs{$task->{duration}}++;

        # Mark all the conflicts which the actively jobs have asserted.
        foreach my $conflict (@{$task->{conflicts}}) {
            $active_conflicts{$conflict}++;

            # This should never happen.
            $active_conflicts{$conflict} < 2 or die("Unexpected parallel conflict '$conflict' ($active_conflicts{$conflict}) running at this time!");
        }
    }

    return $self->{+STATE_CACHE} = {
        running    => $running,
        categories => \%cats,
        durations  => \%durs,
        conflicts  => \%active_conflicts,
    };
}

sub _group_items {
    my $self = shift;
    my ($run, $stage) = @_;

    my $grouped = $self->grouped($run, $stage);
    my $list    = $self->pending($run, $stage);
    my $todo    = $self->todo($run, $stage);

    while (my $item = shift @$list) {
        my $cat = $item->{category};
        my $dur = $item->{duration};

        die "Invalid category: $cat" unless $CATEGORIES{$cat};
        die "Invalid duration: $dur" unless $DURATIONS{$dur};

        $$todo++;
        push @{$grouped->{$cat}->{$dur}} => $item;
    }

    return $grouped;
}

sub _cat_order {
    my $self = shift;
    my ($state) = @_;

    $state ||= $self->_running_state();

    my @cat_order = ('general');

    # Only search immiscible if we have no immsicible running
    unshift @cat_order => 'immiscible' unless $state->{categories}->{immiscible};

    # Only search isolation if nothing it running.
    push @cat_order => 'isolation' unless $state->{running};

    return \@cat_order;
}

sub _dur_order {
    my $self = shift;
    my ($state) = @_;

    my $max = $self->{+JOB_COUNT};
    my $maxm1 = $max - 1;

    $state ||= $self->_running_state();
    my $durs = $state->{durations};

    # 'short' is always ok.
    my @dur_order = ('short');

    # long and medium should be on the front of the search unless we are
    # already running (max - 1) tests of the duration We want long first if
    # we are not saturation on them, followed by medium, whcih is why they
    # are listed in this order.
    for my $c (qw/medium long/) {
        if ($durs->{$c} && $durs->{$c} >= $maxm1) {
            push @dur_order => $c;    # Back of the list
        }
        else {
            unshift @dur_order => $c;    # Front of the list
        }
    }

    return \@dur_order;
}

sub _next_concurrent {
    my $self = shift;
    my ($run, $stage) = @_;

    my $todo = $self->todo($run, $stage);

    my $state = $self->_running_state();
    my ($running, $cats, $durs, $active_conflicts) = @{$state}{qw/running categories durations conflicts/};

    # Only 1 isolation job can be running and 1 is so let's
    # wait for that pid to die.
    return if $cats->{isolation};

    my $cat_order = $self->_cat_order($state);
    my $dur_order = $self->_dur_order($state);
    my $grouped   = $self->_group_items($run, $stage);

    for my $lcat (@$cat_order) {
        for my $ldur (@$dur_order) {
            my $search = $grouped->{$lcat}->{$ldur} or next;

            for (my $i = 0; $i < @$search; $i++) {
                # If the job has a listed conflict and an existing job is running with that conflict, then pick another job.
                my $job_conflicts = $search->[$i]->{conflicts};
                next if first { $active_conflicts->{$_} } @$job_conflicts;

                $$todo--;
                return scalar splice(@$search, $i, 1);
            }
        }
    }

    return;
}

sub write_remaining_exits {
    my $self = shift;

    $self->check_for_fork;

    eval {
        while (1) {
            sleep 1 if $self->killall($self->{+SIGNAL} // 'TERM');
            last unless $self->wait();
        }
        1;
    } or warn $@;

    for my $pid (keys %{$self->{+PROCS}}) {
        my $job = delete $self->{+PROCS}->{$pid};
        delete $self->{+PROCS_BY_CAT}->{$job->category};
        warn "Forcefully terminating pid $pid\n";
        kill('KILL', $pid);
        my $check = waitpid($pid, WNOHANG);
        my $exit = $check == $pid ? $? : -1;

        $job->set_exit($self, $exit, time);
    }
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner - Logic for executing a test run.

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
