package Test2::Harness::Runner;
use strict;
use warnings;

our $VERSION = '1.000155';

use File::Spec();

use Carp qw/confess croak/;
use Fcntl qw/LOCK_EX LOCK_UN/;
use POSIX qw/:sys_wait_h/;
use Long::Jump qw/setjump longjump/;
use Time::HiRes qw/sleep time/;
use Scope::Guard;

use Test2::Harness::Util qw/clean_path file2mod mod2file open_file parse_exit write_file_atomic process_includes chmod_tmp write_file/;
use Test2::Harness::Util::Queue();
use Test2::Harness::Util::JSON(qw/encode_json/);

use Test2::Harness::Runner::Constants;

use Test2::Harness::Runner::Run();
use Test2::Harness::Runner::Job();
use Test2::Harness::Runner::Spawn();
use Test2::Harness::Runner::State();
use Test2::Harness::Runner::Preload();
use Test2::Harness::Runner::Preloader();
use Test2::Harness::Runner::Preloader::Stage();
use Test2::Harness::Runner::DepTracer();

use parent 'Test2::Harness::IPC';
use Test2::Harness::Util::HashBase(
    # Fields from settings
    qw{
        <job_count <slots_per_job

        <includes <tlib <lib <blib
        <unsafe_inc

        <use_fork <preloads <preload_threshold <switches
        <restrict_reload

        <cover

        <event_timeout <post_exit_timeout

        <resources

        <nytprof

        <reload
    },
    # From Construction
    qw{
        <dir <settings <fork_job_callback <fork_spawn_callback <respawn_runner_callback <monitor_preloads
        <jobs_todo <dump_depmap
    },
    # Other
    qw {
        +preloader
        +state

        <stage
        <signal

        +last_timeout_check
        +dispatch_lock_file
        +can_stage
        <tmp_dir

        <rootpid
    },
);

sub job_class  { 'Test2::Harness::Runner::Job' }

our $RUNNER_PID;
sub init {
    my $self = shift;

    $self->{+ROOTPID} = $$;
    $RUNNER_PID = $$;

    croak "'dir' is a required attribute"      unless $self->{+DIR};
    croak "'settings' is a required attribute" unless $self->{+SETTINGS};

    my $dir = clean_path($self->{+DIR});

    croak "'$dir' is not a valid directory"
        unless -d $dir;

    $self->{+DIR} = $dir;

    $self->{+HANDLERS}->{HUP} = sub {
        my $sig = shift;
        print "$$ $0 ($self->{+STAGE}) Runner caught SIG$sig, reloading...\n";
        $self->{+SIGNAL} = $sig;
    };

    my $tmp_dir = File::Spec->catdir($self->{+DIR}, 'tmp');
    unless (-d $tmp_dir) {
        mkdir($tmp_dir) or die "Could not create temp dir: $!";
        chmod_tmp($tmp_dir);
    }
    $self->{+TMP_DIR} = $tmp_dir;

    my $have_job_limiter = 0;
    for my $res (@{$self->{+RESOURCES}}) {
        require(mod2file($res)) unless ref($res);
        $have_job_limiter++ if $res->job_limiter;
    }

    unless ($have_job_limiter) {
        require Test2::Harness::Runner::Resource::JobCount;
        unshift @{$self->{+RESOURCES}} => 'Test2::Harness::Runner::Resource::JobCount';
    }

    $self->SUPER::init();
}

sub preloader {
    my $self = shift;

    $self->{+PRELOADER} //= Test2::Harness::Runner::Preloader->new(
        dir             => $self->{+DIR},
        preloads        => $self->preloads,
        monitor         => $self->{+MONITOR_PRELOADS},
        restrict_reload => $self->{+RESTRICT_RELOAD},
        dump_depmap     => $self->{+DUMP_DEPMAP},
        reload          => $self->{+RELOAD},

        below_threshold => ($self->{+PRELOAD_THRESHOLD} && $self->{+JOBS_TODO} && $self->{+PRELOAD_THRESHOLD} > $self->{+JOBS_TODO}) ? 1 : 0,
    );
}

sub state {
    my $self = shift;

    my $preloader = $self->preloader;

    my $settings = $self->settings;
    $self->{+STATE} //= Test2::Harness::Runner::State->new(
        workdir      => $self->{+DIR},
        eager_stages => $preloader->eager_stages // {},
        preloader    => $preloader,
        resources    => [map { $_->new(settings => $settings) } @{$self->{+RESOURCES}}],
        settings     => $settings,
    );
}

sub check_timeouts {
    my $self = shift;

    return unless $self->settings->runner->use_timeout;

    my $now = time;

    # Check only once per second, that is as granular as we get. Also the check is not cheep.
    return if $self->{+LAST_TIMEOUT_CHECK} && $now < (1 + $self->{+LAST_TIMEOUT_CHECK});

    for my $pid (keys %{$self->{+PROCS}}) {
        my $job = $self->{+PROCS}->{$pid};
        next unless $job->isa('Test2::Harness::Runner::Job');
        next unless $job->use_timeout;

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

        write_file_atomic($job->et_file,  "$now $delta") if $e_to  && !-f $job->et_file;
        write_file_atomic($job->pet_file, "$now $delta") if $pe_to && !-f $job->pet_file;

        my $sigmap = $self->SIG_MAP;
        my $sig = $kill ? $sigmap->{'KILL'} : $sigmap->{'TERM'};

        $sig = "-$sig" if $self->USE_P_GROUPS;

        print STDERR "$$ $0 " . $job->file . " did not respond to SIGTERM, sending SIGKILL to $pid...\n" if $kill;

        # storing the jobid we had to stop
        $self->{run_reached_timeout} //= {};
        $self->{run_reached_timeout}->{$job->task->{job_id}} = $pid;

        kill($sig, $pid);
    }

    $self->{+LAST_TIMEOUT_CHECK} = time;
}

sub stop {
    my $self = shift;

    $self->check_for_fork;

    if (keys %{$self->{+PROCS}}) {
        print "$$ $0 Sending all child processes the TERM signal...\n";
        # Send out the TERM signal
        $self->killall($self->{+SIGNAL} // 'TERM');
        $self->wait(all => 1, timeout => 5);
    }

    # Time to get serious
    if (keys %{$self->{+PROCS}}) {
        print STDERR "$$ $0 Some child processes are refusing to exit, sending KILL signal...\n";
        print("$$ $0 == $_ " . waitpid($_, WNOHANG) . "\n") for keys %{$self->{+PROCS}};
        $self->killall('KILL');
    }

    $self->SUPER::stop();
}

sub dispatch_lock_file {
    my $self = shift;
    return $self->{+DISPATCH_LOCK_FILE} //= File::Spec->catfile($self->{+DIR}, 'dispatch.lock');
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

    push @out => @{$self->{+INCLUDES}} if $self->{+INCLUDES};

    push @out => 't/lib' if $self->{+TLIB};
    push @out => 'lib'   if $self->{+LIB};

    if ($self->{+BLIB}) {
        push @out => 'blib/lib';
        push @out => 'blib/arch';
    }

    return @out;
}

sub process {
    my $self = shift;

    @INC = process_includes(
        list            => [@{$self->settings->harness->dev_libs}, $self->all_libs],
        include_dot     => $self->unsafe_inc,
        include_current => 1,
        clean           => 1,
    );

    my $pidfile = File::Spec->catfile($self->{+DIR}, 'PID');
    write_file_atomic($pidfile, "$$");

    $self->start();

    my $ok  = eval { $self->run_tests(); 1 };
    my $err = $@;
    $self->{+CAN_STAGE} = 0;

    warn $err unless $ok;

    $self->stop();

    return $self->{+SIGNAL} ? 128 + $self->SIG_MAP->{$self->{+SIGNAL}} : $ok ? 0 : 1;
}

sub spawn_scheduler {
    my $self = shift;

    return unless $self->{+ROOTPID} == $$;

    my $pid = fork // die "Could not fork: $!";
    return $self->watch_pid($pid) if $pid;

    my $guard = Scope::Guard->new(sub {
        print STDERR "\n\nEscaped Scope!!!!\n\n";
        print STDERR $@;
        exit 255;
    });

    $0 =~ s/-runner/-scheduler/i;

    my $state = $self->state;

    my $lock = open_file($self->dispatch_lock_file, '>>');

    while (1) {
        $state->poll;

        flock($lock, LOCK_EX) or die "Could not get scheduler lock: $!";

        while (1) {
            next if $state->advance;
            last;
        }

        flock($lock, LOCK_UN) or die "Could not release scheduler lock: $!";

        if ($self->end_test_loop()) {
            $guard->dismiss;
            exit(0);
        }

        my $slept = 0;
        if ($self->{+WAIT_TIME}) {
            # This sleep is often interrupted by signals.
            while ($slept < $self->{+WAIT_TIME}) {
                $slept += sleep($self->{+WAIT_TIME} - $slept);
            }
        }
    }

    warn "Escaped scheduler loop";
    exit 255;
}

sub run_tests {
    my $self = shift;

    my $preloader = $self->preloader;
    $preloader->preload();

    $self->spawn_scheduler();

    my ($stage, @procs) = $preloader->preload_stages();

    if ($self->dump_depmap) {
        if (my $dtrace = $preloader->dtrace) {
            if (my $depmap = $dtrace->dep_map) {
                my $file = "depmap-$stage.json";
                write_file($file, encode_json($depmap));
            }
        }
    }

    $self->watch($_) for @procs;

    while(1) {
        $self->{+CAN_STAGE} = 1;
        my $jump = setjump "Stage-Runner" => sub {
            $self->run_stage($stage);
        };

        last unless $jump;

        ($stage) = @$jump;
        $self->reset_stage();
    }

    return;
}

sub reset_stage {
    my $self = shift;

    # Normalize IPC
    $self->check_for_fork();

    # If no stage was set we do not want to clear this, root stages need to
    # preserve the preloads
    return unless $self->{+STAGE};

    # From Runner
    delete $self->{+STAGE};
    delete $self->{+STATE};
    delete $self->{+LAST_TIMEOUT_CHECK};

    return;
}

sub run_stage {
    my $self = shift;
    my ($stage) = @_;

    $self->{+STAGE} = $stage;
    $self->state->stage_ready($stage);

    while (1) {
        next if $self->run_job();

        next if $self->wait();

        last if $self->end_test_loop();

        sleep($self->{+WAIT_TIME}) if $self->{+WAIT_TIME};
    }

    $self->state->stage_down($stage);

    $self->killall($self->{+SIGNAL}) if $self->{+SIGNAL};

    $self->wait(all => 1);

    exit 0 unless $stage eq 'base' || $stage eq 'default';
}

sub run_job {
    my $self = shift;

    my $task = $self->state->next_task($self->{+STAGE}) or return 0;

    if ($task->{spawn} && !$task->{resource_skip}) {
        my $job = Test2::Harness::Runner::Spawn->new(
            runner        => $self,
            task          => $task,
            settings      => $self->settings,
            fork_callback => $self->{+FORK_SPAWN_CALLBACK},
        );

        $self->{+FORK_SPAWN_CALLBACK}->($self, $job);
        return 1;
    }

    my $run = $self->state->run();
    return 1 unless $run;

    my $job_class;
    if ($task->{job_class}) {
        $job_class = $task->{job_class};
        require(mod2file($job_class));

        die "Custom job class $job_class overrode the category, this is a fatal mistake"
            unless $job_class->category eq $self->job_class->category;
    }
    else {
        $job_class = $self->job_class;
    }

    my $job = $job_class->new(
        runner        => $self,
        task          => $task,
        run           => $run,
        settings      => $self->settings,
        fork_callback => $self->{+FORK_JOB_CALLBACK},
    );

    $job->prepare_dir();

    my $spawn_time;

    my $pid;
    my $via = $job->via();
    if ($via) {
        require(mod2file($1)) if !defined(&{$via}) && $via =~ m/^(.+)::[^:]+$/;

        $spawn_time = time();
        $pid        = $self->$via($job);
        $job->set_pid($pid);
        $self->watch($job);
    }
    else {
        $spawn_time = time();
        $self->spawn($job);
        $pid = $job->pid;
    }

    my $json_data = $job->TO_JSON();
    $json_data->{stamp} = $spawn_time;
    $run->jobs->write($json_data);

    return $pid;
}

sub end_test_loop {
    my $self = shift;

    my $state = $self->state;

    no warnings 'uninitialized';
    if (!$self->{+STAGE} || $self->{+STAGE} eq 'default' || $self->{+STAGE} eq 'base') {
        $self->{+RESPAWN_RUNNER_CALLBACK}->()
            if $self->preloader->check($state) || ($self->{+SIGNAL} && $self->{+SIGNAL} eq 'HUP');
    }

    if ($self->preloader->check($state)) {
        $self->{+SIGNAL} //= 'HUP';
        return 1;
    }

    return 1 if $self->{+SIGNAL};

    return 1 if $state->done;

    return 0;
}

sub set_proc_exit {
    my $self = shift;
    my ($proc, $exit, $time, @args) = @_;

    if ($proc->isa('Test2::Harness::Runner::Job')) {
        my $task = $proc->task;

        my $timed_out = 0;
        if ( !$exit && ref $self->{run_reached_timeout} && $self->{run_reached_timeout}->{ $task->{job_id} } ) {
            delete $self->{run_reached_timeout}->{ $task->{job_id} };
            $timed_out = 1;
        }

        if (($exit || $timed_out) && $proc->is_try < $proc->retry ) {
            $self->state->retry_task($task->{job_id});
            push @args => 'will-retry';
        }
        else {
            $self->state->stop_task($task->{job_id});
        }

        if(my $bail = $exit ? $proc->bailed_out : 0) {
            print "$$ $0 BAIL-OUT detected: $bail\n";
            if ($self->settings->runner->abort_on_bail) {
                print "$$ $0 Aborting the test run...\n";
                $self->state->halt_run($task->{run_id});
            }
        }
    }
    elsif ($proc->isa('Test2::Harness::Runner::Preloader::Stage')) {
        my $stage = $proc->name;

        if ($exit != 0) {
            my $e = parse_exit($exit);
            my $err = "$$ $0 Child stage '$stage' did not exit cleanly (sig: $e->{sig}, err: $e->{err})!\n";
            $self->{+MONITOR_PRELOADS} ? warn $err : die $err;
        }

        if ($self->{+MONITOR_PRELOADS} && $self->{+CAN_STAGE} && !$self->end_test_loop) {
            my $pid = $$;
            my ($name, @procs) = $self->preloader->_preload_stages($stage);
            $self->watch($_) for @procs;
            longjump "Stage-Runner" => $name unless $pid == $$;
        }
    }

    $self->SUPER::set_proc_exit($proc, $exit, $time, @args);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner - Base class for test runners

=head1 DESCRIPTION

This module does the heavy lifting of running all the tests.

You should never need to create an instance of the runner yourself. In most
cases the runner module is exposed via a callback or a plugin affordance.

=head1 PUBLIC METHODS

=head2 FROM SETTINGS

These are attributesd with values set from the L<Test2::Harness::Settings>
instance created from command line arguments.

See L<App::Yath::Options::Runner> for the most up to date documentation on
these.

=over 4

=item $runner->includes

=item $runner->tlib

=item $runner->lib

=item $runner->blib

=item $runner->unsafe_inc

=item $runner->use_fork

=item $runner->preloads

=item $runner->preload_threshold

=item $runner->switches

=item $runner->cover

=item $runner->event_timeout

=item $runner->post_exit_timeout

=back

=head2 FROM CONSTRUCTION

These attributes are set when the runner is created.

=over 4

=item $path = $runner->dir

Path to the working directory.

=item $settings = $runner->settings

The L<App::Yath::Settings> instance.

=item $coderef = $runner->fork_job_callback

Callback used to spawn new tests via fork.

=item $coderef = $runner->respawn_runner_callback

Callback to restart the runner process.

=item $bool = $runner->monitor_preloads

True if preloads should be watched for changes.

=item $int = $runner->jobs_todo

A count of total jobs to run. This will always be 0 in a persistent runner.

=back

=head2 OTHER PUBLIC METHODS

If a method is not documented here then it is an implementation detail and you
should not use it.

=over 4

=item $class = $runner->job_class

Class for new test jobs.

=item $preload = $runner->preloader

Get the L<Test2::Harness::Runner::Preloader> instance.

=item $state = $runner->state

Get the L<Test2::Harness::Runner::State> instance.

=item @list = $runner->all_libs

Get all the libs that should be added to @INC by default. Note that specific
runs and even specific tests can have custom paths on top of these.

=back

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
