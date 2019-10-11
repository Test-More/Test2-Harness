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

sub clear_finished_run {
    my $self = shift;

    # More to do!
    return if $self->{+STATE}->todo;

    # Still running, some may need a retry
    return if $self->{+STATE}->running;

    return $self->SUPER::clear_finished_run();
}

sub run_tests {
    my $self = shift;

    $self->{+STATE}->mark_stage_ready('default');

    until ($self->end_test_loop()) {
        my $run = $self->run or last;

        my $task = $self->next();
        $self->run_job($run, $task) if $task;

        next if $self->wait(cat => $self->job_class->category);
        next if $task;

        sleep($self->{+WAIT_TIME}) if $self->{+WAIT_TIME};
    };

    $self->wait(all => 1);
}

sub end_test_loop {
    my $self = shift;

    return 0 unless $self->end_task_loop;

    return 0 if @{$self->poll_runs};
    return 1 if $self->{+RUNS_ENDED};

    return 0;
}

sub end_task_loop {
    my $self = shift;

    return 0 if $self->{+STATE}->todo;
    return 0 if $self->{+STATE}->running;
    return 1 if $self->queue_ended;

    return 0;
}

sub next {
    my $self = shift;

    my $iter = 0;
    until ($self->end_task_loop()) {
        $self->poll_tasks();

        # Reap any completed PIDs
        $self->wait();

        my $task = $self->{+STATE}->pick_and_start('default');

        return $task if $task;

        sleep($self->{+WAIT_TIME}) if $self->{+WAIT_TIME};
    }

    return undef;
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
