package Test2::Harness::Run::Runner::ProcMan::Scheduler::Finite;
use strict;
use warnings;

our $VERSION = '0.001036';

use List::Util qw/sum/;

use parent 'Test2::Harness::Run::Runner::ProcMan::Scheduler';
use Test2::Harness::Util::HashBase qw/-index -queues/;

sub GEN() { 'general' }
sub LNG() { 'long' }
sub MED() { 'medium' }
sub IMM() { 'immiscible' }
sub ISO() { 'isolation' }

sub init {
    my $self = shift;

    $self->{+INDEX} = 0;

    $self->{+QUEUES} = { map { $_ => [] } GEN, LNG, MED, IMM, ISO };
}

sub fetch {
    my $self = shift;
    my ($max, $pending, $running) = @_;

    my $queues = $self->{+QUEUES};

    while (@$pending > $self->{+INDEX}) {
        my $task = $pending->[$self->{+INDEX}++];
        my $cat = $task->{category};
        $cat = GEN() unless $cat && $self->{+QUEUES}->{$cat};

        push @{$queues->{$cat}} => $task;
    }

    my $task = $self->_fetch(@_);

    if (defined($task)) {
        $self->{+INDEX}--;
        @$pending = grep { $_->{job_id} ne $task->{job_id} } @$pending;
    }

    return $task;
}

sub _fetch {
    my $self = shift;
    my ($max, $pending, $running) = @_;

    return undef if $running->{+ISO};

    my $queues = $self->{+QUEUES};

    my $gen_running = $running->{+GEN};
    my $imm_running = $running->{+IMM};
    my $lng_running = $running->{+LNG};
    my $med_running = $running->{+MED};
    my $not_short = $lng_running + $med_running;
    my $total = sum($gen_running, $imm_running, $lng_running, $med_running);

    return undef if $total >= $max;

    # Long and Medium float to the top, but only if the slots are not all
    # saturated with them.
    if ($not_short < ($max - 1)) {
        return shift @{$queues->{+LNG}} if @{$queues->{+LNG}};
        return shift @{$queues->{+MED}} if @{$queues->{+MED}};
    }

    return shift @{$queues->{+IMM}} if @{$queues->{+IMM}} && !$imm_running;

    return shift @{$queues->{+GEN}} if @{$queues->{+GEN}};

    # At this point we fall back and just run whatever
    return shift @{$queues->{+LNG}} if @{$queues->{+LNG}};
    return shift @{$queues->{+MED}} if @{$queues->{+MED}};

    # Run the iso if we can
    return shift @{$queues->{+ISO}} if @{$queues->{+ISO}} && !grep { @{$_} } values %$queues;

    # Nothing can be run right now
    return undef;
}

1;
