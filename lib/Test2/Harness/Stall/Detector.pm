package Test2::Harness::Stall::Detector;
use strict;
use warnings;

our $VERSION = '1.000175';

use Carp qw/croak/;
use List::Util qw/first/;
use File::Spec();
use Time::HiRes qw/time/;

use Test2::Harness::Util::Queue();

use Test2::Harness::Util::HashBase qw{
    <workdir <job_count
    <strong <loose

    +queue +state
    +last_check +last_start +first_ready
    +scheduler_pid +stage_pids
    +reports +replay_errors
};

# Give up after this many consecutive replay failures. A State handler that
# dislikes a record will dislike it every time, and re-reading the whole
# dispatch file once a second is worse than not reporting.
use constant MAX_REPLAY_ERRORS => 3;

# Actions only the scheduler process enqueues. start_run is the useful one: it
# is written before any task starts, so it is present even in a run where
# nothing ever ran.
my %SCHEDULER_ACTIONS = (start_run => 1, start_task => 1);

# How often check() is allowed to touch the filesystem. The render loop calls
# it thousands of times a second.
use constant CHECK_INTERVAL => 1;

# Wait this long before saying the same stall again, so a benign tail cannot
# flood a CI log, and stop entirely after MAX_REPORTS.
use constant REPEAT_INTERVAL => 300;
use constant MAX_REPORTS     => 5;

sub init {
    my $self = shift;

    croak "You must specify a workdir" unless defined $self->{+WORKDIR};

    $self->{+JOB_COUNT} //= 1;
    $self->{+REPORTS} = [];

    return;
}

# Parse a --stall-report value: 'STRONG:LOOSE', or one number for both.
# Returns nothing when reporting is disabled.
sub parse_spec {
    my $class = shift;
    my ($spec) = @_;

    return unless defined $spec && length "$spec";

    my ($strong, $loose) = split /:/, "$spec", 2;

    $loose = $strong unless defined $loose && length $loose;

    # An opt-in diagnostic that silently disables itself on a typo is a trap:
    # the site turns it on once and only finds out years later.
    for my $val ($strong, $loose) {
        croak "Invalid --stall-report value '$spec', want SECONDS or STRONG:LOOSE"
            unless defined $val && $val =~ m/^\d+(?:\.\d+)?$/;
    }

    return if $strong <= 0 && $loose <= 0;

    return (strong => $strong, loose => $loose);
}

# A State that can never reach a user resource class. State::init only builds
# the classes named in the settings when 'resources' is empty, so handing it an
# in-tree resource means _stop_task's release() only ever reaches JobCount.
# Without this the main process would run the very callback most likely to be
# wedged. Do not remove the resources argument.
sub build_state {
    my $self = shift;

    # Loaded here rather than at compile time: the collector loads this module
    # only to ask whether reporting is on, and should not pay for the runner's
    # state machine to answer that.
    require Test2::Harness::Runner::State;
    require Test2::Harness::Runner::Resource::JobCount;

    return Test2::Harness::Runner::State->new(
        workdir   => $self->{+WORKDIR},
        job_count => $self->{+JOB_COUNT},
        observe   => 1,
        resources => [
            Test2::Harness::Runner::Resource::JobCount->new(
                job_count => $self->{+JOB_COUNT},
            ),
        ],
    );
}

# Read only for the record stamps State does not expose. last_job_activity is
# no use here, it moves when a test stops as well as when one starts.
sub queue {
    my $self = shift;

    return $self->{+QUEUE} //= Test2::Harness::Util::Queue->new(
        file => File::Spec->catfile($self->{+WORKDIR}, 'dispatch.jsonl'),
    );
}

sub poll_stamps {
    my $self = shift;

    my $items = eval { [$self->queue->poll] };

    unless ($items) {
        my $count = ++$self->{+REPLAY_ERRORS};
        warn "Stall detector could not read the dispatch queue: $@" if $count <= MAX_REPLAY_ERRORS;
        return 0;
    }

    for my $item (@$items) {
        my $data   = $item->[-1]     or next;
        my $action = $data->{action} or next;
        my $stamp  = $data->{stamp};

        $self->{+LAST_START} = $stamp if $action eq 'start_task';

        if ($action eq 'stage_ready') {
            $self->{+FIRST_READY} //= $stamp;
            $self->{+STAGE_PIDS}->{$data->{item}} = $data->{pid} if $data->{pid};
        }

        # A stage that has gone down must leave the list. Its pid can be
        # recycled, and SIGUSR1 to a process that never installed the handler
        # kills it.
        delete $self->{+STAGE_PIDS}->{$data->{item}} if $action eq 'stage_down';

        $self->{+SCHEDULER_PID} //= $data->{pid}
            if $data->{pid} && $SCHEDULER_ACTIONS{$action};
    }

    return 1;
}

sub stage_pids { $_[0]->{+STAGE_PIDS} // {} }

sub replay {
    my $self = shift;

    # State's handlers die on anything they consider inconsistent, and they
    # were not written for read-only replay in another process. State::init
    # polls as its last act, so construction can die too and has to be inside
    # the same guard. A detector must never be able to end a healthy run.
    my $state = $self->{+STATE};
    my $ok    = eval {
        $state //= $self->build_state();
        $state->poll;
        1;
    };
    my $err = $@;

    unless ($ok) {
        $self->{+STATE} = undef;

        my $count = ++$self->{+REPLAY_ERRORS};

        warn "Stall detector could not read the run state: $err";
        warn "Stall reporting disabled after $count failures.\n" if $count == MAX_REPLAY_ERRORS;

        return;
    }

    $self->{+STATE} = $state;

    return $state;
}

sub pending_tasks {
    my $self = shift;
    my ($state) = @_;

    my @out;
    my $pending = $state->pending_tasks // {};
    for my $run_id (keys %$pending) {
        for my $smoke (values %{$pending->{$run_id} // {}}) {
            for my $stage (values %{$smoke // {}}) {
                for my $cat (values %{$stage // {}}) {
                    for my $dur (values %{$cat // {}}) {
                        push @out => @{$dur // []};
                    }
                }
            }
        }
    }

    return \@out;
}

# True when every pending test is one the scheduler is right to be holding
# back. These waits are legitimate and can last as long as the longest running
# test, so reporting them would be noise.
sub all_pending_blocked {
    my $self = shift;
    my ($state, $tasks) = @_;

    my $running    = $state->running            // 0;
    my $categories = $state->running_categories // {};
    my $conflicts  = $state->running_conflicts  // {};
    my $shares     = $state->running_shares     // {};

    for my $task (@$tasks) {
        my $cat = $task->{category} // 'general';

        next if $cat eq 'isolation'  && $running;
        next if $cat eq 'immiscible' && $categories->{immiscible};

        # These mirror the two rejections in State::_next. An exclusive claim
        # waits for anything holding the name, exclusively or shared; a shared
        # claim waits only for an exclusive holder.
        next if first { $conflicts->{$_} || $shares->{$_} } @{$task->{conflicts} // []};
        next if first { $conflicts->{$_} } @{$task->{shares}                     // []};

        return 0;
    }

    return 1;
}

sub check {
    my $self = shift;

    return unless $self->{+STRONG} || $self->{+LOOSE};
    return if @{$self->{+REPORTS}} >= MAX_REPORTS;
    return if ($self->{+REPLAY_ERRORS} // 0) >= MAX_REPLAY_ERRORS;

    my $now = time;
    return if $self->{+LAST_CHECK} && $now - $self->{+LAST_CHECK} < CHECK_INTERVAL;
    $self->{+LAST_CHECK} = $now;

    my $polled = $self->poll_stamps();
    my $state  = $self->replay() or return;

    # Both readers got through in this call, so nothing is persistently wrong.
    # Consecutive, as MAX_REPLAY_ERRORS says: a healthy run must clear it, not
    # only a run that is about to report.
    $self->{+REPLAY_ERRORS} = 0 if $polled;

    return unless $self->{+FIRST_READY};
    return unless grep { $_ } values %{$state->stage_readiness // {}};

    my $tasks = $self->pending_tasks($state);
    return unless @$tasks;

    my $running   = $state->running // 0;
    my $tier      = $running ? 'loose'         : 'strong';
    my $threshold = $running ? $self->{+LOOSE} : $self->{+STRONG};
    return unless $threshold;

    my $since = $now - ($self->{+LAST_START} // $self->{+FIRST_READY});
    return if $since < $threshold;

    return if $self->all_pending_blocked($state, $tasks);

    my $last = $self->{+REPORTS}->[-1];
    return if $last && $now - $last < REPEAT_INTERVAL;

    push @{$self->{+REPORTS}} => $now;

    return {
        tier      => $tier,
        idle      => $since,
        threshold => $threshold,
        running   => $running,
        pending   => scalar(@$tasks),
        round     => scalar(@{$self->{+REPORTS}}),
        state     => $state,
        tasks     => $tasks,

        scheduler_pid => $self->{+SCHEDULER_PID},
        stage_pids    => $self->stage_pids,
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Stall::Detector - Notice when the scheduler has stopped
starting tests.

=head1 DESCRIPTION

A stall is new tests not being started even though tests are pending and there
is capacity to start them. Whether other tests are currently running is
irrelevant; a stall is about what is not being started.

This class decides when that has happened. It is driven from the main
C<yath test> process, which is healthy during a stall and is an ancestor of the
scheduler. It adds no bookkeeping to the runner: everything it needs is already
in the run's own C<dispatch.jsonl>.

Two readers are involved. A raw L<Test2::Harness::Util::Queue> supplies the
record stamps, because C<last_job_activity> moves when a test stops as well as
when one starts. A L<Test2::Harness::Runner::State> replay supplies the counts.

The replay is built with an explicit in-tree C<resources> list.
C<Test2::Harness::Runner::State> only constructs the resource classes named in
the settings when none are supplied, so passing one keeps C<release()> away
from user code -- the callback most likely to be wedged when this fires. B<Do
not remove that argument.>

Nothing here may end a healthy run, so the replay is wrapped and repeated
failures disable reporting rather than repeating forever.

=head2 WHAT IS NOT A STALL

Two waits are suppressed, because the scheduler is right to hold back and both
can last as long as the longest running test: pending tests that are all
C<isolation> while something is running, and pending tests all blocked by a
conflict already held. Reporting is also gated on a stage being currently
ready, so a long preload is not mistaken for a stall.

=head1 SYNOPSIS

    use Test2::Harness::Stall::Detector;

    my %spec = Test2::Harness::Stall::Detector->parse_spec('600:1200')
        or return;

    my $detector = Test2::Harness::Stall::Detector->new(
        %spec,
        workdir   => $workdir,
        job_count => $job_count,
    );

    # Called often; it rate-limits itself.
    if (my $found = $detector->check) {
        ...
    }

=head1 ATTRIBUTES

=over 4

=item $string = $detector->workdir()

The run's working directory.

=item $int = $detector->job_count()

Used only to build the replay's job limiter.

=item $seconds = $detector->strong()

How long to wait before reporting while tests are pending and none are running.

=item $seconds = $detector->loose()

How long to wait before reporting while tests are pending and others are still
running.

=back

=head1 PUBLIC METHODS

=over 4

=item %spec = $class->parse_spec($string)

Parses a C<--stall-report> value, either C<SECONDS> or C<STRONG:LOOSE>. Returns
an empty list when reporting is disabled, and croaks on an unparseable value.

=item $hashref = $detector->check()

Returns nothing unless a stall is being reported. Rate-limits itself, so it is
safe to call from a busy loop. The returned hashref describes what was
observed, and carries the replayed state, the pending tasks, and the scheduler
and stage pids.

=item $hashref = $detector->stage_pids()

Stage name to pid, for stages that are currently up. These feed the signal
whitelist, so a stage that has gone down is removed.

=item $queue = $detector->queue()

The raw dispatch queue reader, separate from the replay's own. Never
C<$state-E<gt>dispatch_file>: that reader is stateful and the main process
needs it untouched so C<stop()> can replay the whole file on Ctrl-C.

=item $bool = $detector->poll_stamps()

Reads new records for their stamps and pids, returning false if the queue
could not be read. C<last_job_activity> cannot serve here, because it moves
when a test stops as well as when one starts.

=item $state = $detector->build_state()

Builds the observer state. See the warning above about the C<resources>
argument.

=item $state = $detector->replay()

Polls the observer state, returning nothing if it could not be read. Repeated
failures disable reporting rather than re-reading the whole queue every second
for the rest of the run.

=item $arrayref = $detector->pending_tasks($state)

Every pending task across all runs, flattened.

=item $bool = $detector->all_pending_blocked($state, $tasks)

Whether every pending test is one the scheduler is right to be holding back:
an C<isolation> test while anything runs, an C<immiscible> one while another
immiscible runs, an exclusive claim on a name something else holds either way,
or a shared claim on a name something holds exclusively. These mirror the
rejections in C<State::_next> and must follow it.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
