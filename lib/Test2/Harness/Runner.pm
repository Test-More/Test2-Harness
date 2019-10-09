package Test2::Harness::Runner;
use strict;
use warnings;

our $VERSION = '0.001100';

use File::Spec();

use Test2::Harness::Runner::Job();

use Carp qw/croak/;
use Time::HiRes qw/time/;

use Test2::Harness::Util qw/clean_path mod2file write_file_atomic/;

use Test2::Harness::Runner::Constants;

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
        <dir <settings <fork_job_callback
    },
    # Other
    qw {
        <signal

        +preload_done

        +last_timeout_check
    },
);

sub init {
    my $self = shift;

    croak "'dir' is a required attribute" unless $self->{+DIR};
    croak "'settings' is a required attribute" unless $self->{+SETTINGS};

    my $dir = clean_path($self->{+DIR});

    croak "'$dir' is not a valid directory"
        unless -d $dir;

    $self->{+DIR} = $dir;

    $self->{+JOB_COUNT} //= 1;

    $self->SUPER::init();
}

sub completed_task { }

sub queue_ended { $_[0]->run->queue_ended }
sub job_class   { 'Test2::Harness::Runner::Job' }
sub task_stage  { 'default' }

sub run        { croak(ref($_[0]) . " Does not implement run()") }
sub run_tests  { croak(ref($_[0]) . " Does not implement run_tests()") }
sub add_task   { croak(ref($_[0]) . " Does not implement add_task()") }
sub retry_task { croak(ref($_[0]) . " Does not implement retry_task()") }

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
    push @out => clean_path('lib') if $self->{+LIB};

    if ($self->{+BLIB}) {
        push @out => clean_path('blib/lib');
        push @out => clean_path('blib/arch');
    }

    push @out => map { clean_path($_) } @{$self->{+INCLUDES}} if $self->{+INCLUDES};

    return @out;
}

sub run_job {
    my $self = shift;
    my ($run, $task) = @_;

    my $job = $self->job_class->new(
        runner   => $self,
        task     => $task,
        run      => $run,
        settings => $self->settings,
    );

    print "Starting: " . $job->file . " \n";

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

    print "Started $pid: " . $job->file . " \n" if $pid;

    return $pid;
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

        write_file_atomic($job->et_file,  $now) if $e_to && !-f $job->et_file;
        write_file_atomic($job->pet_file, $now) if $pe_to && !-f $job->pet_file;

        my $sig = $kill ? 'KILL' : 'TERM';
        $sig = "-$sig" if $self->USE_P_GROUPS;

        print STDERR $job->file . " did not respond to SIGTERM, sending SIGKILL to $pid...\n" if $kill;

        kill($sig, $pid);
    }

    $self->{+LAST_TIMEOUT_CHECK} = time;
}

sub set_proc_exit {
    my $self = shift;
    my ($proc, $exit, $time, @args) = @_;

    if ($proc->isa('Test2::Harness::Runner::Job')) {
        my $task = $proc->task;

        if ($exit && $proc->is_try < $proc->retry) {
            $task = {%$task}; # Clone
            $task->{is_try}++;
            $self->retry_task($task);
            push @args => 'will-retry';
        }
        else {
            $self->completed_task($task);
        }
    }

    $self->SUPER::set_proc_exit($proc, $exit, $time, @args);
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
        $self->killall('KILL')
    }

    $self->SUPER::stop();
}


sub poll_tasks {
    my $self = shift;

    return if $self->queue_ended;

    my $run = $self->run;
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
