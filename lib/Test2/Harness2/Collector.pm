package Test2::Harness2::Collector;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use POSIX qw/:sys_wait_h setpgid/;
use IO::Handle;
use IO::Select;
use Time::HiRes qw/sleep time/;
use Atomic::Pipe;
use Scope::Guard ();

use Test2::Harness2::Util qw/now_dt/;
use Test2::Harness2::Util::IPC qw/
    swap_io
    parse_exit
    pid_is_running
    set_procname
    apply_atomic_pipe_compression
    atomic_pipe_compression_args
/;
use Test2::Harness2::Util::JSON qw/decode_json encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use Test2::Harness2::Event;

# Child memory (peak RSS) is read from getrusage(RUSAGE_CHILDREN) when
# BSD::Resource is available. It is an optional dependency (Suggests) -- when
# it is absent the exit event simply omits the memory facet. CPU timing comes
# from the core times() builtin and is always present.
my $HAVE_BSD_RESOURCE = do {
    my $ok = eval { require BSD::Resource; 1 };
    $ok ? 1 : 0;
};

use constant DEFAULT_KILL_TIMEOUT    => 5;
use constant DEFAULT_ORPHAN_TIMEOUT  => 30;
use constant DEFAULT_FLUSH_INTERVAL  => 0.25;
use constant FALLBACK_SELECT_TIMEOUT => 1.0;

my @FORWARDED_SIGNALS = qw/TERM INT QUIT/;
my @IGNORED_SIGNALS   = qw/USR1 USR2 HUP PIPE/;

use Object::HashBase qw{
    <is_test
    <exec_command
    <run_sub
    <events_file
    <parser
    <processor
    <orphan_timeout
    <silence_timeout
    <lifetime_timeout
    <watch_parent_pid
    <buffering
    <flush_interval
    <collector_row
    <artifact_row
    -child_pid
    -out_pipe
    -err_pipe
    -pipes
    -by_fh
    -sel
    -events_writer
    -start_time
    -last_activity
    -last_flush
    -wait_status
    -orphaned
    -timed_out
    -parent_exited
    -kill_state
    -buffer
    -start_times
    -fork_stamp
    -end_times
    -reap_stamp
    -child_maxrss
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector - Fork a child process and feed its events through
a parser / processor pipeline into a zstd events file.

=head1 DESCRIPTION

Entry point for the collector subsystem. C<start> forks a single child,
wires the child's STDOUT and STDERR to mixed-mode L<Atomic::Pipe>s, and in
the collector parent drives the event pipeline:

    bytes  ->  parser  ->  optional processor  ->  events file

The parser turns raw stream lines and pre-decoded JSON message bursts into
L<Test2::Harness2::Event> objects. The optional processor sees one event at a
time and may drop it, pass it through, or expand it into several events. The
resulting events are written to the C<events_file> as a multi-frame zstd
file, one self-contained frame per event.

Each message burst arrives with the on-wire zstd frame cached on the event's
C<compressed_form> slot; when present, that frame is written verbatim instead
of being re-encoded. A processor that modifies an event must delete its
C<compressed_form> so the changed event is re-encoded (see
L<Test2::Harness2::Collector::Role::Processor>).

The collector returns C<0> when the pipeline finished cleanly, regardless of
the collected process's own exit status. The collected process's exit shows
up as a C<harness_process_exit> event in the stream, not in the collector's
return value. The collector returns C<255> only when it itself failed
internally before the pipeline could finish.

=head1 SYNOPSIS

    use Test2::Harness2::Collector;

    my $exit = Test2::Harness2::Collector->start(
        is_test     => 1,
        events_file => "$dir/events.jsonl.zst",
        exec_command => [$^X, '-Ilib', 't/foo.t'],
    );

C<start> is a thin convenience that constructs a collector via C<new> and
then calls C<run_collector> on it.

=head1 ATTRIBUTES

=over 4

=item events_file (required)

Path to the multi-frame zstd events file the collector writes. Opened for
append in the parent after the fork.

=item exec_command => \@argv

A command + args list to C<exec> in the child. Mutually exclusive with
C<run_sub>.

=item run_sub => \&callback

A code reference to invoke in the child instead of C<exec>. Called with one
argument: a L<Scope::Guard> that catches the callback escaping the
collector's scope. A callback that intends to unwind the stack itself (e.g.
via L<Long::Jump>) must call C<< $guard->dismiss >> first. Mutually
exclusive with C<exec_command>.

=item parser => $instance_or_class

L<Test2::Harness2::Collector::Role::Parser> implementer. When omitted, a
test job (C<is_test> true) defaults to
L<Test2::Harness2::Collector::Parser::TAPParser> and a non-test job defaults
to L<Test2::Harness2::Collector::Parser::IOParser>. A bare class name is
constructed with no arguments.

=item processor => $instance_or_class

Optional L<Test2::Harness2::Collector::Role::Processor> implementer. A bare
class name is constructed with no arguments. When absent, parsed events are
written straight through.

=item is_test => 0 | 1

When true, the child is placed in a fresh process group via C<setpgid(0, 0)>
so the test cannot signal the collector tree, and the test-only silence /
lifetime timeouts apply.

=item orphan_timeout => $seconds

How long the collector keeps reading after the collected process has exited
before declaring the pipes orphaned and giving up. Default C<30>; C<0>
disables (wait for EOF indefinitely).

=item silence_timeout => $seconds

Test-job only. Maximum interval with no output on either pipe while the child
runs, before the collector kills it. Default C<0> (disabled).

=item lifetime_timeout => $seconds

Test-job only. Maximum total runtime before the collector kills the child.
Default C<0> (disabled).

=item watch_parent_pid => $pid

Optional. When set, the collector watches C<$pid> (typically the process that
launched the collector). If that process disappears while the child is still
running, the collector emits a C<harness_parent_exit> event and terminates
the child rather than continuing as an orphan. Default C<undef> (disabled).

=item buffering => $bool

When true (the default), the collector buffers per-stream entries and uses
the STDOUT-event / STDERR-sync-marker pairing to keep raw output ordered
against the structured events that bracket it. When false, every record
dispatches immediately and STDERR sync markers are dropped.

=item flush_interval => $seconds

Maximum time buffered records are held before a forced flush, so raw output
is not hidden during long pauses between structured events. Default C<0.25>;
C<0> disables the periodic flush. Ignored when C<buffering> is false.

=item collector_row => $row_object

Optional duck-typed row object supplied by the launching process. Only
C<< ->update(\%changes) >> is called on it. When absent the collector does no
row lifecycle writes.

=item artifact_row => $row_object

Optional duck-typed row object for the artifact record. Only
C<< ->update(\%changes) >> is called on it (to store the raw events-file
bytes). When absent the collector does no artifact row writes.

=back

=head1 PUBLIC METHODS

=cut

=over 4

=item $exit = Test2::Harness2::Collector->start(%args)

Convenience constructor + driver: C<< $class->new(%args)->run_collector >>.

=back

=cut

sub start ($class, %args) {
    my $self = $class->new(%args);
    return $self->run_collector;
}

sub init ($self) {
    $self->{+IS_TEST} = $self->{+IS_TEST} ? 1 : 0;

    croak "exec_command or run_sub must be supplied"
        unless $self->{+EXEC_COMMAND} || $self->{+RUN_SUB};
    croak "exec_command and run_sub are mutually exclusive"
        if $self->{+EXEC_COMMAND} && $self->{+RUN_SUB};

    croak "events_file is a required attribute"
        unless defined $self->{+EVENTS_FILE} && length $self->{+EVENTS_FILE};

    $self->{+ORPHAN_TIMEOUT}   //= DEFAULT_ORPHAN_TIMEOUT;
    $self->{+SILENCE_TIMEOUT}  //= 0;
    $self->{+LIFETIME_TIMEOUT} //= 0;
    $self->{+BUFFERING}        //= 1;
    $self->{+FLUSH_INTERVAL}   //= DEFAULT_FLUSH_INTERVAL;

    $self->{+PARSER}    = $self->_coerce_parser($self->{+PARSER});
    $self->{+PROCESSOR} = $self->_coerce_processor($self->{+PROCESSOR});

    $self->{+ORPHANED}  = 0;
    $self->{+TIMED_OUT} = 0;

    return;
}

=over 4

=item $exit = $self->run_collector

Fork once, run the requested command (or callback) in the child, and run the
event pipeline in the collector parent until both pipes hit EOF and the child
has been reaped (or one of the configured timeouts fires). May only be called
once per collector instance.

=back

=cut

sub run_collector ($self) {
    my ($out_r, $out_w) = Atomic::Pipe->pair(
        mixed_data_mode => 1,
        atomic_pipe_compression_args(),
    );
    my ($err_r, $err_w) = Atomic::Pipe->pair(
        mixed_data_mode => 1,
        atomic_pipe_compression_args(),
    );

    $self->{+START_TIMES} = [times()];

    my $child = fork // die "fork: $!";

    if ($child == 0) {
        $out_r->close;
        $err_r->close;

        my $child_guard = Scope::Guard::guard(sub {
            print STDERR "Child process escaped collector scope!\n";
            POSIX::_exit(255);
        });

        my $ok  = eval { $self->_run_child($child_guard, $out_w, $err_w); 1 };
        my $err = $@;
        warn "Collector child died: $err\n" unless $ok;

        $child_guard->dismiss;
        POSIX::_exit($ok ? 0 : 255);
    }

    $out_w->close;
    $err_w->close;

    $self->{+CHILD_PID} = $child;
    $self->_record_collector_child($child);
    $self->{+FORK_STAMP}    = time;
    $self->{+OUT_PIPE}      = $out_r;
    $self->{+ERR_PIPE}      = $err_r;
    $self->{+EVENTS_WRITER} = open_zstd_writer($self->{+EVENTS_FILE});

    $self->_set_procname;

    my $ok  = eval { $self->_run_parent; 1 };
    my $err = $@;

    if (!$ok) {
        warn "Collector failed: $err\n";
        $self->_safe_kill;
    }

    unless (defined $self->{+WAIT_STATUS}) {
        waitpid($child, 0);
        $self->_note_reap($?);
    }

    $self->_finalize;

    return $ok ? 0 : 255;
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $obj = $self->_coerce_parser($thing)

=item $obj = $self->_coerce_processor($thing)

Turn an attribute that may be a blessed object, a bare class name, or
(parser only) C<undef> into an instance. An omitted parser defaults to
L<Test2::Harness2::Collector::Parser::TAPParser> for a test job
(C<is_test> true) and L<Test2::Harness2::Collector::Parser::IOParser>
otherwise; the processor stays C<undef> when not supplied.

=back

=cut

sub _coerce_parser ($self, $thing) {
    return $thing if blessed($thing);

    if (!defined $thing) {
        my $class =
            $self->{+IS_TEST}
            ? 'Test2::Harness2::Collector::Parser::TAPParser'
            : 'Test2::Harness2::Collector::Parser::IOParser';
        $self->_require_class($class);
        return $class->new;
    }

    if (!ref($thing)) {
        $self->_require_class($thing);
        return $thing->new;
    }

    croak "'parser' must be a class name or an object, not a " . ref($thing);
}

sub _coerce_processor ($self, $thing) {
    return undef unless defined $thing;
    return $thing if blessed($thing);

    if (!ref($thing)) {
        $self->_require_class($thing);
        return $thing->new;
    }

    croak "'processor' must be a class name or an object, not a " . ref($thing);
}

sub _require_class ($self, $class) {
    (my $file = $class) =~ s{::}{/}g;
    require "$file.pm";
    return;
}

=over 4

=item $self->_run_child($guard, $out_w, $err_w)

Child-side bootstrap: replace STDOUT / STDERR with the mixed-mode pipe
writers, mark the environment so a Test2 stream formatter recognises it is
inside a collector, and for test jobs select that formatter via
C<T2_FORMATTER> and place the process in a fresh process group. Finally
either C<exec> the requested command or invoke the callback.

=back

=cut

sub _run_child ($self, $guard, $out_w, $err_w) {
    $out_w->blocking(1);
    $err_w->blocking(1);

    swap_io(\*STDOUT, $out_w->wh);
    swap_io(\*STDERR, $err_w->wh);

    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    $ENV{T2_HARNESS2_PIPE_COUNT} = 2;

    # Test jobs run Test2; point Test2::API at our stream formatter (it
    # prepends "Test2::Formatter::" to the value) and place them in a fresh
    # process group so the test cannot signal the collector tree.
    if ($self->{+IS_TEST}) {
        $ENV{T2_FORMATTER} = 'Stream2';
        setpgid(0, 0);
    }

    if (my $exec = $self->{+EXEC_COMMAND}) {
        CORE::exec(@$exec) or die "exec(@$exec) failed: $!";
    }

    $self->{+RUN_SUB}->($guard);
    return;
}

=over 4

=item $self->_run_parent

Parent-side IO loop: select on both pipe read ends, decode message bursts to
events through the parser, optionally route through the processor, write to
the events file. Continues until both pipes hit EOF, until one of the
configured timeouts fires, or until the orphan watchdog gives up.

=back

=cut

sub _run_parent ($self) {
    my $out = $self->{+OUT_PIPE};
    my $err = $self->{+ERR_PIPE};

    apply_atomic_pipe_compression($out);
    apply_atomic_pipe_compression($err);

    local %SIG = %SIG;
    $self->_install_signal_handlers;

    my $sel = IO::Select->new;
    $sel->add($out->rh);
    $sel->add($err->rh);
    $self->{+SEL} = $sel;

    $self->{+PIPES} = {
        out => {stream => 'stdout', pipe => $out, eof => 0},
        err => {stream => 'stderr', pipe => $err, eof => 0},
    };
    $self->{+BY_FH} = {
        $out->rh => $self->{+PIPES}{out},
        $err->rh => $self->{+PIPES}{err},
    };

    $self->{+START_TIME}    = time;
    $self->{+LAST_ACTIVITY} = $self->{+START_TIME};
    $self->{+LAST_FLUSH}    = $self->{+START_TIME};
    $self->{+BUFFER}        = {seen => {}, saw_event => 0, stdout => [], stderr => []}
        if $self->{+BUFFERING};

    my $st = $self->_compute_select_timeouts;

    while ($sel->count) {
        my $timeout =
              defined $self->{+WAIT_STATUS} ? $st->{dead}
            : $self->{+KILL_STATE}          ? $st->{dying}
            :                                 $st->{alive};
        my @ready = $sel->can_read($timeout);

        my $activity = 0;
        if (@ready) {
            for my $fh (@ready) {
                my $slot = $self->{+BY_FH}{$fh} or next;
                $slot->{pipe}->fill_buffer;
                $activity += $self->_drain_one_pipe($slot);
            }
        }
        else {
            $activity += $self->_drain_pipes;
        }

        $self->{+LAST_ACTIVITY} = time if $activity;

        $self->_periodic_flush;
        $self->_poll_child;
        $self->_check_parent;
        $self->_check_test_job_timeouts;
        $self->_escalate_kill;

        last if $self->_check_orphan;
    }

    $self->_drain_pipes;
    $self->_flush_buffer;

    return;
}

=over 4

=item $st = $self->_compute_select_timeouts

Precompute the C<select> timeout to use while the child is alive, while it is
being killed, and after it has exited, folding in the flush interval and the
configured timeouts.

=back

=cut

sub _compute_select_timeouts ($self) {
    my @flush;
    push @flush => $self->{+FLUSH_INTERVAL}
        if $self->{+BUFFER} && $self->{+FLUSH_INTERVAL};

    my @alive;
    if ($self->{+IS_TEST}) {
        push @alive => $self->{+SILENCE_TIMEOUT}  if $self->{+SILENCE_TIMEOUT};
        push @alive => $self->{+LIFETIME_TIMEOUT} if $self->{+LIFETIME_TIMEOUT};
    }

    my @dead;
    push @dead => $self->{+ORPHAN_TIMEOUT} if $self->{+ORPHAN_TIMEOUT};

    return {
        alive => $self->_min_or_fallback(@flush, @alive),
        dying => $self->_min_or_fallback(@flush, DEFAULT_KILL_TIMEOUT),
        dead  => $self->_min_or_fallback(@flush, @dead),
    };
}

sub _min_or_fallback ($self, @vals) {
    return FALLBACK_SELECT_TIMEOUT unless @vals;
    my $min = $vals[0];
    for my $v (@vals[1 .. $#vals]) {
        $min = $v if $v < $min;
    }
    return $min;
}

=over 4

=item $self->_periodic_flush

Flush buffered records once the flush interval has elapsed, even when no
event-pair has arrived to trigger a natural sync flush.

=back

=cut

sub _periodic_flush ($self) {
    return unless $self->{+FLUSH_INTERVAL};
    my $buf = $self->{+BUFFER} or return;
    return if (time - $self->{+LAST_FLUSH}) < $self->{+FLUSH_INTERVAL};
    return unless @{$buf->{stdout}} || @{$buf->{stderr}};

    $self->_flush_buffer;
    return;
}

=over 4

=item $self->_poll_child

Non-blocking C<waitpid> for the child; record its wait status the first time
it is seen to have exited.

=back

=cut

sub _poll_child ($self) {
    return if defined $self->{+WAIT_STATUS};

    my $child = $self->{+CHILD_PID};
    my $r     = waitpid($child, WNOHANG);

    return if $r == 0;

    # When waitpid returns -1 (no such child) the child was already reaped or
    # never existed; on Windows pseudo-process pids are negative so this branch
    # also covers the pid==-1 corner case. Treat the child as done with a 0
    # status either way.
    $self->_note_reap($r == $child ? $? : 0);
    return;
}

=over 4

=item $self->_note_reap($status)

Record the child's wait status the first time it is seen to have exited,
snapshotting the C<times()> CPU counters, the wall-clock reap time, and the
child's peak memory at the same moment so the exit event can report them.

=back

=cut

sub _note_reap ($self, $status) {
    return if defined $self->{+WAIT_STATUS};

    $self->{+WAIT_STATUS}  = $status;
    $self->{+END_TIMES}    = [times()];
    $self->{+REAP_STAMP}   = time;
    $self->{+CHILD_MAXRSS} = $self->_child_maxrss;
    return;
}

=over 4

=item $kb = $self->_child_maxrss

Peak resident set size of the reaped child in kilobytes, read from
C<getrusage(RUSAGE_CHILDREN)>. Returns C<undef> when L<BSD::Resource> is not
installed or the lookup fails.

=back

=cut

sub _child_maxrss ($self) {
    return undef unless $HAVE_BSD_RESOURCE;

    my $maxrss;
    my $ok = eval {
        # ru_maxrss is field index 2 of the getrusage list. For
        # RUSAGE_CHILDREN it is the peak RSS of the largest reaped child.
        my @ru = BSD::Resource::getrusage(BSD::Resource::RUSAGE_CHILDREN());
        $maxrss = $ru[2];
        1;
    };
    my $err = $@;
    warn "getrusage failed: $err\n" unless $ok;

    return $ok ? $maxrss : undef;
}

=over 4

=item $self->_set_procname

Set C<$0> on the collector parent so process listings identify it as a
collector wrapping a particular child (its argv, or C<run_sub> for a
callback).

=back

=cut

sub _set_procname ($self) {
    my @parts = ('collector');
    push @parts => $self->{+CHILD_PID} if $self->{+CHILD_PID};

    if (my $exec = $self->{+EXEC_COMMAND}) {
        push @parts => join(' ', @$exec);
    }
    elsif ($self->{+RUN_SUB}) {
        push @parts => 'run_sub';
    }

    set_procname(set => [join(' - ', @parts)]);
    return;
}

=over 4

=item $self->_check_parent

When a C<watch_parent_pid> was supplied, detect that the watched process has
disappeared while the child is still running: emit a C<harness_parent_exit>
event and C<SIGTERM> the child so it does not keep running detached.

=back

=cut

sub _check_parent ($self) {
    my $ppid = $self->{+WATCH_PARENT_PID} or return;
    return if defined $self->{+WAIT_STATUS};
    return if $self->{+KILL_STATE};
    return if $self->{+PARENT_EXITED};

    # 0 means the watched process is gone; 1 (ours) and -1 (alive, not ours)
    # both mean it is still around.
    return unless pid_is_running($ppid) == 0;

    $self->{+PARENT_EXITED} = 1;
    $self->_emit_parent_exit_event($ppid);

    kill 'TERM', $self->{+CHILD_PID};
    $self->{+KILL_STATE} = {sig => 'TERM', stamp => time};
    return;
}

=over 4

=item $self->_check_test_job_timeouts

Test-job only: trip the silence or lifetime timeout when its limit is
reached while the child is still running.

=back

=cut

sub _check_test_job_timeouts ($self) {
    return unless $self->{+IS_TEST};
    return if defined $self->{+WAIT_STATUS};
    return if $self->{+KILL_STATE};

    my $now = time;

    my $activity_delta = $now - $self->{+LAST_ACTIVITY};
    if ($self->{+SILENCE_TIMEOUT} && $activity_delta >= $self->{+SILENCE_TIMEOUT}) {
        $self->_trip_timeout(silence => $activity_delta);
        return;
    }

    my $lifetime_delta = $now - $self->{+START_TIME};
    if ($self->{+LIFETIME_TIMEOUT} && $lifetime_delta >= $self->{+LIFETIME_TIMEOUT}) {
        $self->_trip_timeout(lifetime => $lifetime_delta);
        return;
    }

    return;
}

sub _trip_timeout ($self, $kind, $delta) {
    my $limit_attr = $kind eq 'silence' ? +SILENCE_TIMEOUT : +LIFETIME_TIMEOUT;

    $self->{+TIMED_OUT} = $kind;
    $self->_emit_timeout_event(
        kind  => $kind,
        limit => $self->{$limit_attr},
        delta => $delta,
    );

    kill 'TERM', $self->{+CHILD_PID};
    $self->{+KILL_STATE} = {sig => 'TERM', stamp => time};
    return;
}

=over 4

=item $self->_escalate_kill

Escalate a pending C<SIGTERM> to C<SIGKILL> once the kill-grace has elapsed
and the child still has not exited.

=back

=cut

sub _escalate_kill ($self) {
    my $kill_state = $self->{+KILL_STATE} or return;
    return if defined $self->{+WAIT_STATUS};
    return unless $kill_state->{sig} eq 'TERM';
    return unless (time - $kill_state->{stamp}) >= DEFAULT_KILL_TIMEOUT;

    kill 'KILL', $self->{+CHILD_PID};
    $self->{+KILL_STATE} = {sig => 'KILL', stamp => time};
    return;
}

=over 4

=item $bool = $self->_check_orphan

After the child has exited, give up (returning true) when the pipes stay open
with no further output past the orphan timeout.

=back

=cut

sub _check_orphan ($self) {
    return 0 unless defined $self->{+WAIT_STATUS};
    return 0 unless $self->{+ORPHAN_TIMEOUT};
    return 0 unless $self->{+SEL}->count;
    return 0 unless (time - $self->{+LAST_ACTIVITY}) >= $self->{+ORPHAN_TIMEOUT};

    $self->{+ORPHANED} = 1;
    $self->_emit_orphan_event;
    return 1;
}

=over 4

=item $count = $self->_drain_pipes

=item $count = $self->_drain_one_pipe($slot)

Pull every currently-available record off the pipe(s), handing each to
C<_handle_pipe_record>, and mark a pipe slot EOF when its read end closes.
Return the number of records handled.

=back

=cut

sub _drain_pipes ($self) {
    my $count = 0;
    for my $slot (values %{$self->{+PIPES}}) {
        next if $slot->{eof};
        $count += $self->_drain_one_pipe($slot);
    }
    return $count;
}

sub _drain_one_pipe ($self, $slot) {
    my $pipe   = $slot->{pipe};
    my $stream = $slot->{stream};
    my $count  = 0;

    while (1) {
        my ($type, $data, %extra) = $pipe->get_line_burst_or_data;

        unless (defined $type) {
            if ($pipe->eof) {
                $self->{+SEL}->remove($pipe->rh);
                $slot->{eof} = 1;
            }
            return $count;
        }

        $count++;
        $self->_handle_pipe_record($stream, $type, $data, \%extra);
    }
}

=over 4

=item $self->_handle_pipe_record($stream, $type, $data, \%extra)

Route one pipe record. When buffering, event bursts and raw lines are queued
as parsed events and released through C<_flush_buffer> using sync-marker
pairing; otherwise records dispatch immediately through C<_handle_direct>.

A structured burst is either an event (JSON hash) or a sync marker (JSON
array C<[pid, ordinal]>). Markers are never recorded -- the producer writes
the same marker to both STDOUT (right after its event) and STDERR, and the
collector uses the matched pair as the cross-stream flush point.

=item $self->_event_from_burst($stream, $data, \%extra)

Decode an event burst and turn it into a L<Test2::Harness2::Event> via the
parser, carrying the on-wire compressed frame through C<compressed> for
verbatim writing. Returns C<undef> (with a warning) on a decode failure.

=item $bool = $self->_is_sync_marker($data)

True when a structured-burst payload is a sync marker (a JSON array) rather
than an event (a JSON hash).

=back

=cut

sub _handle_pipe_record ($self, $stream, $type, $data, $extra) {
    return $self->_handle_direct($stream, $type, $data, $extra)
        unless $self->{+BUFFER};

    my $buf = $self->{+BUFFER};

    if ($type eq 'burst' || $type eq 'message') {
        if ($self->_is_sync_marker($data)) {
            $buf->{saw_event} = 1;
            push @{$buf->{$stream}} => {sync => $data};
            $self->_flush_buffer(to => $data) if ++$buf->{seen}{$data} >= 2;
            return;
        }

        $buf->{saw_event} = 1;
        my $event = $self->_event_from_burst($stream, $data, $extra) or return;
        push @{$buf->{$stream}} => {event => $event};
        return;
    }

    if ($type eq 'line') {
        chomp $data;
        my $event = $self->{+PARSER}->parse_io(stream => $stream, line => $data);
        push @{$buf->{$stream}} => {event => $event} if $event;

        # Before any structured event has been seen there is nothing to pair
        # raw lines against -- flush immediately so they reach the events
        # file in arrival order.
        $self->_flush_buffer unless $buf->{saw_event};
        return;
    }

    return;
}

sub _event_from_burst ($self, $stream, $data, $extra) {
    my $decoded = eval { decode_json($data) };
    unless ($decoded) {
        warn "decode_json failed on $stream burst\n";
        return undef;
    }

    return $self->{+PARSER}->parse_io(
        stream => $stream,
        event  => $decoded,
        (defined $extra->{compressed} ? (compressed => $extra->{compressed}) : ()),
    );
}

sub _is_sync_marker ($self, $data) {
    return $data =~ m/\A\s*\[/ ? 1 : 0;
}

sub _handle_direct ($self, $stream, $type, $data, $extra) {
    if ($type eq 'line') {
        chomp $data;
        my $event = $self->{+PARSER}->parse_io(stream => $stream, line => $data);
        $self->_dispatch_event($event) if $event;
        return;
    }

    if ($type eq 'burst' || $type eq 'message') {
        # Sync markers have no pairing role without buffering -- drop them.
        return if $self->_is_sync_marker($data);

        my $event = $self->_event_from_burst($stream, $data, $extra) or return;
        $self->_dispatch_event($event);
        return;
    }

    return;
}

=over 4

=item $self->_flush_buffer(%params)

Release buffered records to the processor / events file in stream-order
(stderr then stdout). With C<< to => $marker >> the flush stops after the
matching sync marker in each stream, leaving later records queued. Sync
markers themselves are consumed (clearing their pairing state) but never
written.

=back

=cut

sub _flush_buffer ($self, %params) {
    my $buf = $self->{+BUFFER} or return;
    my $to  = $params{to};

    for my $stream (qw/stderr stdout/) {
        my $queue = $buf->{$stream};
        while (my $entry = shift @$queue) {
            if (my $event = $entry->{event}) {
                $self->_dispatch_event($event);
                next;
            }

            my $key = $entry->{sync};
            delete $buf->{seen}{$key};
            last if defined($to) && $key eq $to;
        }
    }

    $self->{+LAST_FLUSH} = time;
    return;
}

=over 4

=item $self->_dispatch_event($event)

Route one event through the optional processor and write each resulting event
to the events file.

=item $self->_write_event($event)

Write a single event to the events file. When the event still carries its
on-wire C<compressed_form> frame, that frame is appended verbatim; otherwise
the event is JSON-encoded and compressed into a fresh frame.

=back

=cut

sub _dispatch_event ($self, $event) {
    my $processor = $self->{+PROCESSOR};
    my @events    = $processor ? $processor->process_event($event) : ($event);
    $self->_write_event($_) for @events;
    return;
}

sub _write_event ($self, $event) {
    my $writer     = $self->{+EVENTS_WRITER};
    my $compressed = $event->{compressed_form};

    if (defined $compressed) {
        warn "events file write (raw frame) failed: $@\n"
            unless eval { $writer->print_raw_frame($compressed); 1 };
        return;
    }

    warn "events file write failed: $@\n"
        unless eval { $writer->print(encode_json($event), "\n"); 1 };
    return;
}

=over 4

=item $self->_emit_timeout_event(%args)

=item $self->_emit_orphan_event

=item $self->_emit_parent_exit_event($ppid)

Build and dispatch the synthetic C<harness_timeout> / C<harness_orphan> /
C<harness_parent_exit> events the collector raises when it kills a runaway
test job, gives up on orphaned pipes, or sees its watched parent disappear.
Each flushes the buffer first so the synthetic event lands after the output it
describes.

=back

=cut

sub _emit_timeout_event ($self, %args) {
    my $kind  = $args{kind};
    my $limit = $args{limit};
    my $delta = sprintf('%.2f', $args{delta});

    my %reasons = (
        silence  => "Test produced no output on STDOUT or STDERR for ${limit}s " . "(waited ${delta}s); the collector terminated it. " . "Increase or disable the silence timeout for slow tests.",
        lifetime => "Test exceeded its maximum lifetime of ${limit}s " . "(ran ${delta}s); the collector terminated it. " . "Increase or disable the lifetime timeout for long-running tests.",
    );

    my $event = Test2::Harness2::Event->new(
        facet_data => {
            harness_timeout => {
                kind          => $kind,
                limit_seconds => $limit + 0,
                delta_seconds => $args{delta} + 0,
                stamp         => time,
            },
            errors => [{
                tag          => 'TIMEOUT',
                fail         => 1,
                from_harness => 1,
                details      => "A $kind timeout occurred after ${delta}s; the collector is killing the test.",
            }],
            info => [{
                tag       => 'TIMEOUT',
                debug     => 1,
                important => 1,
                details   => $reasons{$kind},
            }],
        },
    );

    $self->_flush_buffer;
    $self->_dispatch_event($event);
    return;
}

sub _emit_orphan_event ($self) {
    my $orphan_timeout = $self->{+ORPHAN_TIMEOUT};
    my $wait_status    = $self->{+WAIT_STATUS};

    my $details = sprintf(
        "Collected process exited (wait status %s) but pipes remained open; " . "collector waited %ss with no further output before giving up. " . "Likely a descendant process inherited the pipe and outlived its parent.",
        $wait_status, $orphan_timeout,
    );

    my $event = Test2::Harness2::Event->new(
        facet_data => {
            harness_orphan => {
                stamp         => time,
                quiet_seconds => $orphan_timeout,
                wait_status   => $wait_status,
            },
            info => [{
                tag     => 'ORPHAN',
                debug   => 1,
                details => $details,
            }],
        },
    );

    $self->_flush_buffer;
    $self->_dispatch_event($event);
    return;
}

sub _emit_parent_exit_event ($self, $ppid) {
    my $event = Test2::Harness2::Event->new(
        facet_data => {
            harness_parent_exit => {
                stamp      => time,
                parent_pid => $ppid,
            },
            info => [{
                tag       => 'PARENT',
                debug     => 1,
                important => 1,
                details   => "Watched parent process $ppid exited while the test was still running; the collector is terminating the child.",
            }],
        },
    );

    $self->_flush_buffer;
    $self->_dispatch_event($event);
    return;
}

=over 4

=item $self->_install_signal_handlers

Forward C<TERM> / C<INT> / C<QUIT> from the collector to the child and ignore
C<USR1> / C<USR2> / C<HUP> / C<PIPE> for the duration of the run.

=back

=cut

sub _install_signal_handlers ($self) {
    my $child = $self->{+CHILD_PID};
    $SIG{$_} = 'IGNORE' for @IGNORED_SIGNALS;
    for my $sig (@FORWARDED_SIGNALS) {
        $SIG{$sig} = sub { kill $sig, $child };
    }
    return;
}

=over 4

=item $self->_safe_kill

Best-effort teardown used when the parent loop itself died: C<SIGTERM> the
child, wait out the kill-grace, then C<SIGKILL>.

=back

=cut

sub _safe_kill ($self) {
    my $child = $self->{+CHILD_PID} or return;
    kill 'TERM', $child;
    my $deadline = time + DEFAULT_KILL_TIMEOUT;
    while (time < $deadline) {
        $self->_poll_child;
        return if defined $self->{+WAIT_STATUS};
        sleep 0.05;
    }
    kill 'KILL', $child;
    return;
}

=over 4

=item $self->_finalize

Tail of the parent path: synthesize the C<harness_process_exit> event,
dispatch it through the pipeline, and close the events file. The event
carries the decoded wait status (C<sig> / C<err> / C<dmp> / C<all>), any
C<orphaned> / C<timed_out> / C<parent_exited> flags, the child's CPU and
wall-clock timing, and -- when L<BSD::Resource> is available -- its peak
memory. All of these are deduced by the time the child is reaped, so they
ride on the single exit event rather than separate events.

=item $facet = $self->_exit_facet

Assemble the C<harness_process_exit> facet hash described above.

=item $self->_record_collector_child($child_pid)

Stamp the optional collector row with this collector's pid, the forked child
pid, start time, and run mode.

=item $self->_record_collector_stopped

Stamp the optional collector row's stop time and the collector's own clean
exit status (the child's status rides the exit event).

=item $self->_record_artifact_data

Slurp the events file into the optional artifact row's data blob once the
child is done; the on-disk file stays until finalize_run removes it.

=back

=cut

sub _finalize ($self) {
    my $event = Test2::Harness2::Event->new(
        facet_data => {harness_process_exit => $self->_exit_facet},
    );
    $self->_dispatch_event($event);

    if (my $writer = $self->{+EVENTS_WRITER}) {
        warn "events file close failed: $@\n" unless eval { $writer->close; 1 };
    }

    $self->_record_artifact_data;
    $self->_record_collector_stopped;
    return;
}

sub _record_collector_child ($self, $child_pid) {
    my $row = $self->{+COLLECTOR_ROW} or return;
    $row->update({pid => $$, child_pid => $child_pid, started => now_dt(), mode => 'run'});
    return;
}

sub _record_collector_stopped ($self) {
    my $row = $self->{+COLLECTOR_ROW} or return;
    $row->update({stopped => now_dt(), exit_code => 0, exit_signal => 0});
    return;
}

sub _record_artifact_data ($self) {
    my $row  = $self->{+ARTIFACT_ROW} or return;
    my $file = $self->{+EVENTS_FILE};
    return unless $file && -e $file;

    my $bytes = do {
        open my $fh, '<:raw', $file or do { warn "open $file: $!\n"; return };
        local $/;
        <$fh>;
    };
    $row->update({data => $bytes});
    return;
}

sub _exit_facet ($self) {
    my $status = $self->{+WAIT_STATUS} // 0;
    my $px     = parse_exit($status);

    my %facet = (
        sig   => $px->{sig},
        err   => $px->{err},
        dmp   => $px->{dmp} ? 1 : 0,
        all   => $px->{all},
        stamp => $self->{+REAP_STAMP} // time,
        ($self->{+ORPHANED}      ? (orphaned      => 1)                   : ()),
        ($self->{+TIMED_OUT}     ? (timed_out     => $self->{+TIMED_OUT}) : ()),
        ($self->{+PARENT_EXITED} ? (parent_exited => 1)                   : ()),
    );

    if (my $end = $self->{+END_TIMES}) {
        my $start = $self->{+START_TIMES} // [0, 0, 0, 0];
        my %times = (
            child     => {user => $end->[2] - $start->[2], system => $end->[3] - $start->[3]},
            collector => {user => $end->[0] - $start->[0], system => $end->[1] - $start->[1]},
        );
        $times{wall} = $self->{+REAP_STAMP} - $self->{+FORK_STAMP}
            if defined $self->{+REAP_STAMP} && defined $self->{+FORK_STAMP};
        $facet{times} = \%times;
    }

    $facet{memory} = {child_maxrss => $self->{+CHILD_MAXRSS} + 0, unit => 'KB'}
        if defined $self->{+CHILD_MAXRSS};

    return \%facet;
}

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
