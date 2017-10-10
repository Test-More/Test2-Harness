package Test2::Harness::Run::Runner::ProcMan::Scheduler::Fair;
use strict;
use warnings;

our $VERSION = '0.001019';

use parent 'Test2::Harness::Run::Runner::ProcMan::Scheduler::Finite';
use Test2::Harness::Util::HashBase;

sub GEN() { 'general' }
sub LNG() { 'long' }
sub ISO() { 'isolation' }

sub _fetch {
    my $self = shift;
    my ($max, $pending, $running) = @_;

    return undef if $running->{+ISO};

    if (@$pending && $pending->[0]->{category} eq ISO) {
        my $queues = $self->{+QUEUES};

        # Run the iso if we can
        return shift @{$queues->{+ISO}} unless grep { @{$_} } values %$queues;

        # If a long test is running we can run a general while we wait
        return shift @{$queues->{+GEN}} if $running->{+LNG} && @{$queues->{+GEN}};

        # Cannot run anything yet
        return undef;
    }

    # Fall back on the finite algorithm
    return $self->SUPER::_fetch(@_);
}

1;
