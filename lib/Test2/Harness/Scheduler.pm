package Test2::Harness::Scheduler;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/confess/;

use Test2::Harness::Util::HashBase qw{
    runner
    resources
};

sub init { }

sub queue_run {
    my $self = shift;
    my ($run) = @_;

    confess "queue_run() is not implemented";
}

sub advance {
    my $self = shift;
    my ($runner) = @_;

    confess "advance() is not implemented";
}

sub job_update {
    my $self = shift;
    my ($update) = @_;

    confess "job_update() is not implemented";
}

sub start {
    my $self = shift;
    $self->runner->start();
}

sub abort { confess "'abort() is not implemented" }
sub kill  { confess "'kill() is not implemented" }

sub terminate { }

1;
