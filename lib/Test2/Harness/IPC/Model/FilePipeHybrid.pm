package Test2::Harness::IPC::Model::FilePipeHybrid;
use strict;
use warnings;

our $VERSION = '1.000146';

use Carp qw/croak confess/;

use Test2::Harness::IPC::Model::Files;
use Test2::Harness::IPC::Model::AtomicPipe;

use parent 'Test2::Harness::IPC::Model';
use Test2::Harness::Util::HashBase qw{
    -files
    -pipes
};

sub init {
    my $self = shift;

    $self->{+FILES} //= Test2::Harness::IPC::Model::Files->new(state => $self->{+STATE}, run_id => $self->{+RUN_ID});
    $self->{+PIPES} //= Test2::Harness::IPC::Model::AtomicPipe->new(state => $self->{+STATE}, run_id => $self->{+RUN_ID});
}

sub get_test_stdout_pair {
    my $self = shift;
    return $self->{+PIPES}->get_test_stdout_pair(@_);
}

sub get_test_stderr_pair {
    my $self = shift;
    return $self->{+PIPES}->get_test_stderr_pair(@_);
}

sub get_test_events_pair {
    my $self = shift;
    return $self->{+PIPES}->get_test_events_pair(@_);
}

sub add_renderer {
    my $self = shift;
    $self->{+FILES}->add_renderer(@_);
}

sub render_event {
    my $self = shift;
    $self->{+FILES}->render_event(@_);
}

sub finish {
    my $self = shift;
    $self->{+FILES}->finish(@_);
    $self->{+PIPES}->finish(@_);
}

1;
