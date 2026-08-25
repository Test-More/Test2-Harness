package BlockingResource;
use strict;
use warnings;

use Time::HiRes qw/sleep time/;

use parent 'Test2::Harness::Runner::Resource';

# Longest to block for. Bounded on purpose: killing a stalled run is out of
# scope, so an unbounded block would leave the run for App::Yath::Tester's own
# timeout to kill, and that kill lands in stop() -> poll() -> release() and
# hangs the test process itself. A run that expects a stack trace out of this
# raises the bound, because it stops blocking the moment the trace is taken.
sub block_for { $ENV{BLOCKING_RESOURCE_MAX} || 8 }

sub available {
    my $self = shift;
    my ($task) = @_;

    # Resources are constructed in several processes. Only the scheduler is
    # being wedged here; blocking the others proves nothing and hangs the run.
    return 1 unless $0 =~ m/scheduler/;

    # Let one test through so the run gets going and a stage comes up.
    return 1 unless $self->{_started};

    # Block once, then let everything through so the run finishes on its own.
    # Nothing ends a stalled run -- reporting never kills -- so a fixture that
    # blocks forever would sit until App::Yath::Tester's own timeout, and that
    # kill lands in stop() -> poll() -> release() and hangs the test process.
    return 1 if $self->{_done_blocking};

    $self->{_blocked_at} //= time;

    # Stop blocking once this process has been asked for its stack, so the
    # trace is taken while the scheduler really is stuck here however slow the
    # machine is. The harness installed the handler that writes the trace;
    # this only notices that it ran.
    my $traced = 0;
    my $handler = $SIG{USR1};
    local $SIG{USR1} = sub {
        $traced++;
        return unless $handler && ref($handler) eq 'CODE';
        $handler->(@_);
    };

    # A loop of short sleeps, not one long one: the detector sends SIGUSR1 and
    # a single sleep would be cut short by it, un-wedging the fixture early.
    my $block_for = $self->block_for;
    while (!$traced && time - $self->{_blocked_at} < $block_for) {
        sleep 0.2;
    }

    $self->{_done_blocking} = 1;

    return 1;
}

sub assign {
    my $self = shift;
    my ($task, $state) = @_;
    $state->{record} = 1;
}

sub record {
    my $self = shift;
    my ($job_id, $val) = @_;
    $self->{_started}++;
}

sub release { }

1;
