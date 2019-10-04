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

        <staged <stages <stage_check <fork_stages

        +preload_done

        +event_timeout_last
        +post_exit_timeout_last
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

    $self->{+STAGES}      = ['default'];
    $self->{+STAGE_CHECK} = { map {($_ => 1)} @{$self->{+STAGES}} };

    $self->{+STAGED}      = [];
    $self->{+FORK_STAGES} = {};

    $self->{+JOB_COUNT} //= 1;

    $self->{+EVENT_TIMEOUT_LAST}     = time;
    $self->{+POST_EXIT_TIMEOUT_LAST} = time;

    $self->SUPER::init();
}

sub completed_task { }

sub queue_ended { $_[0]->run->queue_ended }
sub job_class   { 'Test2::Harness::Runner::Job' }

sub run        { croak(ref($_[0]) . " Does not implement run()") }
sub run_stages { croak(ref($_[0]) . " Does not implement run_stages()") }
sub add_task   { croak(ref($_[0]) . " Does not implement add_task()") }
sub retry_task { croak(ref($_[0]) . " Does not implement retry_task()") }

sub stage_should_fork { $_[0]->{+FORK_STAGES}->{$_[1]} // 0 }

sub process {
    my $self = shift;

    my %seen;
    @INC = grep { !$seen{$_}++ } $self->all_libs, @INC, $self->unsafe_inc ? ('.') : ();

    my $pidfile = File::Spec->catfile($self->{+DIR}, 'PID');
    write_file_atomic($pidfile, "$$");

    $self->start();

    $self->preload;

    my $ok  = eval { $self->run_stages(); 1 };
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

    return unless $mod->isa('Test2::Harness::Runner::Preload');

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

    my $check_ev = $self->{+EVENT_TIMEOUT}     && $now >= ($self->{+EVENT_TIMEOUT_LAST} + $self->{+EVENT_TIMEOUT});
    my $check_pe = $self->{+POST_EXIT_TIMEOUT} && $now >= ($self->{+POST_EXIT_TIMEOUT_LAST} + $self->{+POST_EXIT_TIMEOUT});

    return unless $check_ev || $check_pe;

    $self->{+EVENT_TIMEOUT_LAST}     = $now;
    $self->{+POST_EXIT_TIMEOUT_LAST} = $now;

    for my $pid (keys %{$self->{+PROCS}}) {
        my $job       = $self->{+PROCS}->{$pid};
        my $last_size = $job->last_output_size;
        my $new_size  = $job->output_size;

        # If last_size is undefined then we have never checked this job, so it
        # started since the last loop, do not time it out yet.
        next unless defined $last_size;

        next if $new_size > $last_size;

        my $kill = -f $job->et_file || -f $job->pet_file;

        write_file_atomic($job->et_file,  $now) if $check_ev && !-f $job->et_file;
        write_file_atomic($job->pet_file, $now) if $check_pe && !-f $job->pet_file;

        my $sig = $kill ? 'KILL' : 'TERM';
        $sig = "-$sig" if $self->USE_P_GROUPS;

        print STDERR $job->file . " did not respond to SIGTERM, sending SIGKILL to $pid...\n" if $kill;

        kill($sig, $pid);
    }
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

        my $stage = $task->{stage};
        $stage = 'default' unless $stage && $self->{+STAGE_CHECK}->{$stage};
        $task->{stage} = $stage;

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
