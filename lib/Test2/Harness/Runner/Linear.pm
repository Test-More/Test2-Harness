package Test2::Harness::Runner::Linear;
use strict;
use warnings;

our $VERSION = '0.001100';

use File::Spec();

use Carp qw/confess/;
use List::Util qw/first/;
use Time::HiRes qw/sleep/;

use Test2::Harness::Util::Queue;

use Test2::Harness::Runner::Run();
use Test2::Harness::Runner::Job();
use Test2::Harness::Runner::State();

use Test2::Harness::Runner::Constants;

use parent 'Test2::Harness::Runner';
use Test2::Harness::Util::HashBase(
    qw {
        +queue +run
        +state
    },
);

sub add_task { $_[0]->{+STATE}->add_pending_task($_[1]) }

sub retry_task {
    my $self = shift;
    my ($task) = @_;

    $self->{+STATE}->add_pending_task($task);
    $self->{+STATE}->stop_task($task);
}

sub completed_task {
    my $self = shift;
    my ($task) = @_;

    $self->{+STATE}->stop_task($task);
}

sub init {
    my $self = shift;

    $self->SUPER::init();

    $self->{+STATE} //= Test2::Harness::Runner::State->new(
        concurrent_stages => 0,
        job_count         => $self->{+JOB_COUNT},
    );
}

sub run_stages {
    my $self = shift;

    $self->run(); # Find the run pre-fork since we are not a persistent runner

    for my $stage (@{$self->{+STAGES}}) {
        $self->stage_start($stage) or next;

        $self->task_loop($stage);

        $self->stage_stop($stage);
    }
}

sub stage_fork {
    my $self = shift;
    my ($stage) = @_;

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

    $self->{+STATE}->mark_stage_ready($stage);

    return 1;
}

sub stage_stop {
    my $self = shift;
    my ($stage) = @_;

    return unless $self->stage_should_fork($stage);

    CORE::exit(0);
}

sub run {
    my $self = shift;
    my ($stage) = @_;

    return $self->{+RUN} if $self->{+RUN};

    my $run_queue = Test2::Harness::Util::Queue->new(file => File::Spec->catfile($self->{+DIR}, 'run_queue.jsonl'));
    my @runs = $run_queue->poll();

    confess "More than 1 run was found in the queue for a linear runner"
        if @runs != 2 || defined($runs[1]->[-1]) || !$run_queue->ended;

    return $self->{+RUN} = Test2::Harness::Runner::Run->new(
        %{$runs[0]->[-1]},
        workdir => $self->{+DIR},
    );
}

sub task_loop {
    my $self = shift;
    my ($stage) = @_;

    while (1) {
        my $task = $self->next($stage);

        # If we have no tasks and no pending jobs then we can be sure we are done
        last unless $task || $self->wait(cat => Test2::Harness::Runner::Job->category);

        $self->run_job($self->run, $task) if $task;
    };
}

sub end_loop {
    my $self = shift;
    my ($stage) = @_;

    return 0 if $self->{+STATE}->todo($stage);
    return 0 unless $self->queue_ended;

    return 1;
}

sub next {
    my $self = shift;
    my ($stage) = @_;

    my $iter = 0;
    until ($self->end_loop($stage)) {
        my $task = $self->_next_iter($stage, $iter++);
        return $task if $task;
    }

    return;
}

sub _next_iter {
    my $self = shift;
    my ($stage, $iter) = @_;

    sleep($self->{+WAIT_TIME}) if $iter && $self->{+WAIT_TIME};

    # Check the job files for active and newly kicked off tasks.
    # Updates $list which we use to decide if we need to keep looping.
    $self->poll_tasks();

    # Reap any completed PIDs
    $self->wait();

    my $out = $self->{+STATE}->pick_and_start($stage);
    return $out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Linear - Run through each stage in a linear way.

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
