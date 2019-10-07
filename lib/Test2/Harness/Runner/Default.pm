package Test2::Harness::Runner::Default;
use strict;
use warnings;

our $VERSION = '0.001100';

use File::Spec();

use Carp qw/confess/;
use Time::HiRes qw/sleep/;

use Test2::Harness::Util::Queue;

use Test2::Harness::Runner::Run();
use Test2::Harness::Runner::State();

use Test2::Harness::Runner::Constants;

use parent 'Test2::Harness::Runner';
use Test2::Harness::Util::HashBase qw/ +queue +run +state /;

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
        staged    => 0,
        job_count => $self->{+JOB_COUNT},
    );
}

sub run {
    my $self = shift;

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

sub run_tests {
    my $self = shift;

    $self->{+STATE}->mark_stage_ready('default');

    while (1) {
        my $task = $self->next();

        # If we have no tasks and no pending jobs then we can be sure we are done
        last unless $task || $self->wait(cat => $self->job_class->category);

        $self->run_job($self->run, $task) if $task;
    };
}

sub end_loop {
    my $self = shift;

    return 0 if $self->{+STATE}->todo('default');
    return 0 unless $self->queue_ended;

    return 1;
}

sub next {
    my $self = shift;

    my $iter = 0;
    until ($self->end_loop()) {
        my $task = $self->_next_iter($iter++);
        return $task if $task;
    }

    return;
}

sub _next_iter {
    my $self = shift;
    my ($iter) = @_;

    sleep($self->{+WAIT_TIME}) if $iter && $self->{+WAIT_TIME};

    # Check the job files for active and newly kicked off tasks.
    # Updates $list which we use to decide if we need to keep looping.
    $self->poll_tasks();

    # Reap any completed PIDs
    $self->wait();

    my $out = $self->{+STATE}->pick_and_start('default');
    return $out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Default - Run All tests without any preload-stages.

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
