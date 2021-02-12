package Test2::Harness::Overlord;
use strict;
use warnings;

our $VERSION = '1.000043';

use Carp qw/croak/;
use Time::HiRes qw/time/;
use POSIX ":sys_wait_h";

use Test2::Harness::Util::HashBase qw{
    <stderr <stdout

    <new_event_handles_cb
    <event_handles

    <master_pid

    <pid
    <exit
};

sub init {
    my $self = shift;

    croak "Overlord requires a pid" unless $self->{+PID};

    # Havign these makes things easier later
    $self->{+EVENT_HANDLES} //= [];
    $self->{+NEW_EVENT_HANDLES_CB} //= sub {};
}

sub watch {
    my $self = shift;

    # This process (overlord) should ONLY ever have 1 child process, the one we
    # care about.
    local $SIG{CHLD} = sub {
        $self->wait(fatal => 1);
    };

    # Should set other handlers as well (TERM, INT, HUP, USR1, USR2) so that they break the loop
    # below but write that they were receieved to the logs before exiting
    # Also forward TERM/INT signals to the test as it will have a different pgroup.

    # In case the sigchld already happened
    $self->wait(fatal => 0, inject => {early_exit => 1});

    # Write out a job start event
    # Write to JOB-pstat.jsonl  # start, stop, overlord stop, runner stop, timeouts

    # LOOP
    # collect, audit, and write events (including checking for new event handles, reading them, etc)
    # Monitor for and handle timeouts
    # Monitor master_pid, kill the child and exit if the master pid goes away.
    # Write to JOB-events.jsonl # All events

    # If the test exited with success we exit 0, otherwise 1
    my $exit = $self->{+EXIT} && defined $self->{+EXIT}->{wstat} && $self->{+EXIT}->{wstat} == 0 ? 0 : 1;
    my $exit_time = time;

    # Write the overlord exit event to the pstat and event logs
    # ...

    # Write summary event to full log
    # Null terminate event and pstat logs
    # Atomic-Write JOB-summary.json     # Final result data (pass, fail, counts, time data, start, stop, overlord-stop, cpu usage, etc, timeout status, did runner stop?)

    return $exit;
}

sub wait {
    my $self = shift;
    my (%params) = @_;

    my $check = waitpid($self->{+PID}, WNOHANG);
    my $exit = $?;

    # $check == 0 means the child is still running, if fatal is not set we simply return.
    # fatal being true means we got a signal and 0 means some other process
    # exited, that should not be possible in an overlord.
    return if $check == 0 && !$params{fatal};

    die "Could not wait on child process! (Got $check, exit: $exit)" unless $check == $pid;
    $self->{+EXIT} = {%{$params{inject} // {}}, stamp => time, wstat => $exit};
}


1;
