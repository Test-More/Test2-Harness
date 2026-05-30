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

use Importer Importer => 'import';

use Test2::Harness2::Util::IPC qw/
    swap_io
    parse_exit
    pid_is_running
    set_procname
    apply_atomic_pipe_compression
    atomic_pipe_compression_args
/;
use Test2::Harness2::Util::JSON qw/decode_json encode_json/;
use Test2::Harness2::Event;
use Test2::Util::UUID qw/gen_uuid/;

our @EXPORT_OK = qw/collect spawn_collector/;

# Child memory (peak RSS) is read from getrusage(RUSAGE_CHILDREN) when
# BSD::Resource is available. It is an optional dependency (Suggests) -- when
# it is absent the exit event simply omits the memory facet. CPU timing comes
# from the core times() builtin and is always present.
use constant HAVE_BSD_RESOURCE => do {
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
    <name
    <uuid
    <run_uuid
    <is_test
    <io_events
    <exec_command
    <run_sub
    <child_env
    <parser
    <processor
    <recorder
    <processors
    <encoding
    <orphan_timeout
    <silence_timeout
    <lifetime_timeout
    <watch_parent_pid
    <buffering
    <flush_interval
    <child_pid
    <out_pipe
    <err_pipe
    <pipes
    <by_fh
    <sel
    <start_time
    <last_activity
    <last_flush
    <wait_status
    <orphaned
    <timed_out
    <parent_exited
    <kill_state
    <buffer
    <start_times
    <fork_stamp
    <end_times
    <reap_stamp
    <child_maxrss
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector - Fork a child process and feed its events through
a parser / processor pipeline into a zstd events file.

=head1 DESCRIPTION

The collector subsystem. It forks a single child, wires the child's STDOUT
and STDERR to mixed-mode L<Atomic::Pipe>s, and in the collector parent drives
the event pipeline:

    bytes  ->  parser  ->  optional processor  ->  optional recorder

The parser turns raw stream lines and pre-decoded JSON message bursts into
L<Test2::Harness2::Event> objects. The optional processor sees one event at a
time and may drop it, pass it through, or expand it into several events. The
resulting events are handed to the recorder, which owns the on-disk format
(the base recorder writes a multi-frame C<jsonl.zst> events file, one
self-contained frame per event). The recorder is optional: with none, events
are produced and audited but not written anywhere, so an in-process
L</collect> still returns its info summary while a forked L</spawn_collector>
(whose summary cannot cross the fork) requires one. The collected process's
own exit becomes a synthetic C<harness_process_exit> event dispatched through
the pipeline after all output has drained, so the processor and recorder see
it like any other event.

Each message burst arrives with the on-wire zstd frame cached on the event's
C<compressed_form> slot; when present, the recorder writes that frame verbatim
instead of re-encoding. A processor that modifies an event must delete its
C<compressed_form> so the changed event is re-encoded (see
L<Test2::Harness2::Collector::Role::Processor>).

The polished entry points are the exported functions L</collect> (run in the
current process, returns an info hashref) and L</spawn_collector> (fork a
collector process, return its pid). The L</start> / L</run_collector> methods
are the underlying engine: they return C<0> when the pipeline finished
cleanly and C<255> only on an internal collector failure, regardless of the
collected process's own exit status.

=head1 SYNOPSIS

    use Test2::Harness2::Collector qw/collect spawn_collector/;
    use Test2::Harness2::Collector::Recorder;

    # Run a test in this process and inspect the result.
    my $info = collect(
        is_test  => 1,
        exec     => [$^X, '-Ilib', 't/foo.t'],
        recorder => Test2::Harness2::Collector::Recorder->new(
            events_file => "$dir/events.jsonl.zst",
        ),
    );

    # Or fork a dedicated collector process (a recorder is required here).
    my $pid = spawn_collector(
        is_test  => 1,
        exec     => [$^X, '-Ilib', 't/foo.t'],
        recorder => Test2::Harness2::Collector::Recorder->new(
            events_file => "$dir/events.jsonl.zst",
        ),
    );
    waitpid($pid, 0);

The exported functions are the polished interface; C<start> /
C<run_collector> are the underlying engine, where C<start> is a thin
convenience that constructs a collector via C<new> and then calls
C<run_collector> on it.

=head1 ATTRIBUTES

=over 4

=item name (required)

Name of the thing being collected: the test file for a test job, or the
service name for a service. It is included in the recorder's start
notification so a listener knows what this collector is running.

=item uuid

This collector's identifier. Generated with L<Test2::Util::UUID> during
construction when not supplied; the recorder stamps it on every notification
message so a listener can tell which collector sent it.

=item run_uuid

The run this collector belongs to. B<Required> for test collectors
(C<is_test>); optional for service collectors, where its absence marks the
collector as global. When set it is included in the recorder's start
notification, so a consumer can group collectors by run.

=item recorder => $instance_or_class

Optional pipeline sink: a L<Test2::Harness2::Collector::Role::Recorder>
implementer (blessed instance, class name, or C<[class =E<gt> @args]>). It
receives every event the pipeline produces, including the synthetic
process-exit event, and owns whatever it writes (a file, a database, nothing
at all). When omitted, nothing is recorded -- an in-process L</collect> still
returns its info summary, but L</spawn_collector> throws, since a forked
collector's summary cannot reach the caller.

=item encoding => $charset

Optional charset name. When set, the child's raw (non-structured) output
lines are C<Encode::decode>'d through it before becoming event text, so
non-ASCII output is not mangled. A child may also switch the encoding
mid-stream by emitting a C<control> facet carrying an C<encoding>. Unset by
default (bytes pass through untouched).

=item child_env => \%vars

Optional environment overrides applied in the child before C<exec> (the
functional interface accepts this as C<env>). The harness's own variables
(the pipe count, and C<T2_FORMATTER> for test jobs) are set afterward, so
they take precedence.

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
to L<Test2::Harness2::Collector::Parser::IOParser>. A bare class name (or a
C<[class =E<gt> @args]> arrayref) is constructed accordingly.

=item processor => $instance_or_class

Optional L<Test2::Harness2::Collector::Role::Processor> implementer (blessed
instance, class name, or C<[class =E<gt> @args]>). When absent, parsed events
are passed straight through to the recorder.

=item is_test => 0 | 1

When true, the child is placed in a fresh process group via C<setpgid(0, 0)>
so the test cannot signal the collector tree, and the test-only silence /
lifetime timeouts apply.

=item io_events => 0 | 1

Test jobs only. Controls whether L<Test2::Formatter::Stream2> turns prints and
warnings made inside a subtest into events that fold into that subtest (rather
than loose top-level output). B<On by default>; pin it explicitly to force a
single job on (C<1>) or off (C<0>) via C<T2_HARNESS2_IO_EVENTS>. Leave it unset
to take the child's default (on).

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

=back

=head1 EXPORTS

Nothing is exported by default. The polished functional interface is
available on request:

    use Test2::Harness2::Collector qw/collect spawn_collector/;

=over 4

=item collect

=item $info = collect(%args)

Run a collector in the current process: fork the child, drive the pipeline,
and return once the child has exited and the pipeline has drained. C<%args>
are the L</ATTRIBUTES> below, except that C<exec>, C<run>, and C<env> may be
used as aliases for C<exec_command>, C<run_sub>, and C<child_env>. Returns an
info hashref:

    $info = {
        exit => {                        # the fields parse_exit() returns:
            sig => $signal,              #   terminating signal, 0 if none
            err => $exit_code,           #   decoded exit code (WEXITSTATUS)
            dmp => $core_dumped,         #   core-dump flag
            all => $raw_wait_status,     #   the child's raw wait status ($?)
        },
        # final_state => {...}           # present when the processor (e.g. the
        #                                # auditor) exposes a final_state
    };

When the collector killed the child itself, C<exit> also carries
C<orphaned>, C<timed_out>, or C<parent_exited> as applicable.

=item spawn_collector

=item $pid = spawn_collector(%args)

Fork a dedicated collector process (which in turn forks and collects the
child) and return its pid to the caller. A C<recorder> is required: the
collector process's info summary cannot reach the caller across the fork, so
a recorder is the only way to capture the run; calling without one croaks.
The collector process runs L</collect> and exits C<0> when the run passed and
C<1> when it failed (from the processor's verdict, or the child's own exit
code when there is no verdict). Two processes are created in total: the
collector and its child.

=back

=cut

sub collect (%args) {
    my $self = Test2::Harness2::Collector->new(__PACKAGE__->_normalize_args(%args));
    $self->run_collector;
    return $self->_build_info;
}

sub spawn_collector (%args) {
    my $class = __PACKAGE__;
    my %norm  = $class->_normalize_args(%args);

    croak "spawn_collector requires a recorder (a forked collector's info summary cannot reach the caller)"
        unless $norm{recorder};

    my $pid = fork // die "Could not fork collector process: $!";
    return $pid if $pid;

    $class->_run_spawned(\%norm);    # never returns
}

=head1 PUBLIC METHODS

=cut

=over 4

=item start

=item $exit = Test2::Harness2::Collector->start(%args)

Convenience constructor + driver: C<< $class->new(%args)->run_collector >>.
Returns the raw C<run_collector> status (C<0> clean, C<255> on internal
failure); callers wanting the structured info hash should use L</collect>.

=back

=cut

sub start ($class, %args) {
    my $self = $class->new(%args);
    return $self->run_collector;
}

sub init ($self) {
    $self->{+IS_TEST} = $self->{+IS_TEST} ? 1 : 0;

    croak "name is a required attribute"
        unless defined $self->{+NAME} && length $self->{+NAME};

    croak "run_uuid is a required attribute for test collectors"
        if $self->{+IS_TEST} && !(defined $self->{+RUN_UUID} && length $self->{+RUN_UUID});

    croak "exec_command or run_sub must be supplied"
        unless $self->{+EXEC_COMMAND} || $self->{+RUN_SUB};
    croak "exec_command and run_sub are mutually exclusive"
        if $self->{+EXEC_COMMAND} && $self->{+RUN_SUB};

    $self->{+UUID} //= gen_uuid();

    $self->{+ORPHAN_TIMEOUT}   //= DEFAULT_ORPHAN_TIMEOUT;
    $self->{+SILENCE_TIMEOUT}  //= 0;
    $self->{+LIFETIME_TIMEOUT} //= 0;
    $self->{+BUFFERING}        //= 1;
    $self->{+FLUSH_INTERVAL}   //= DEFAULT_FLUSH_INTERVAL;

    $self->{+PARSER}     = $self->_coerce_parser($self->{+PARSER});
    $self->{+PROCESSORS} = $self->_coerce_processors($self->{+PROCESSOR});
    $self->{+RECORDER}   = $self->_coerce_recorder($self->{+RECORDER});

    # Hand the recorder this collector's identity so the messages it sends to
    # its notification pipes can say which collector they came from and what
    # is being collected.
    if ($self->{+RECORDER} && $self->{+RECORDER}->can('set_collector_info')) {
        $self->{+RECORDER}->set_collector_info(
            uuid => $self->{+UUID},
            name => $self->{+NAME},
            ($self->{+IS_TEST}          ? (try      => 1)                  : ()),    # retry is not implemented yet
            (defined $self->{+RUN_UUID} ? (run_uuid => $self->{+RUN_UUID}) : ()),
        );
    }

    $self->{+ORPHANED}  = 0;
    $self->{+TIMED_OUT} = 0;

    return;
}

=over 4

=item run_collector

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

    $self->{+CHILD_PID}  = $child;
    $self->{+FORK_STAMP} = time;
    $self->{+OUT_PIPE}   = $out_r;
    $self->{+ERR_PIPE}   = $err_r;

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

=item $arrayref = $self->_coerce_processors($thing)

=item $obj = $self->_coerce_recorder($thing)

Coerce a pipeline-part attribute into an instance (or, for processors, a list
of instances) via L</_coerce_class_arg>, applying the part's default when
C<$thing> is C<undef>: the parser defaults to
L<Test2::Harness2::Collector::Parser::TAPParser> for a test job (C<is_test>
true) and L<Test2::Harness2::Collector::Parser::IOParser> otherwise; the
recorder stays C<undef> and the processor list stays empty.
C<_coerce_processors> treats a top-level arrayref as a list of processor
specs run in order, and a bare class name / object as a single processor.

=item _coerce_class_arg

=item $obj = $self->_coerce_class_arg($thing, $label)

Turn a blessed object (returned as-is), a class name (constructed with no
arguments), or a C<[class =E<gt> @args]> arrayref (constructed with those
arguments) into an instance. Croaks for anything else, naming C<$label>.

=back

=cut

sub _coerce_parser ($self, $thing) {
    return $self->_coerce_class_arg($thing, 'parser') if defined $thing;

    my $class =
        $self->{+IS_TEST}
        ? 'Test2::Harness2::Collector::Parser::TAPParser'
        : 'Test2::Harness2::Collector::Parser::IOParser';
    $self->_require_class($class);
    return $class->new;
}

sub _coerce_processors ($self, $thing) {
    return [] unless defined $thing;

    # A top-level arrayref is always a LIST of processor specs; a bare class
    # name or object is a single processor. To pass constructor args, use a
    # list holding one [class => @args] spec: processor => [[ $class, @args ]].
    my @specs = ref($thing) eq 'ARRAY' ? @$thing : ($thing);
    return [map { $self->_coerce_class_arg($_, 'processor') } @specs];
}

sub _coerce_recorder ($self, $thing) {
    return undef unless defined $thing;
    return $self->_coerce_class_arg($thing, 'recorder');
}

sub _coerce_class_arg ($self, $thing, $label) {
    return $thing if blessed($thing);

    if (ref($thing) eq 'ARRAY') {
        my ($class, @args) = @$thing;
        $self->_require_class($class);
        return $class->new(@args);
    }

    if (!ref($thing)) {
        $self->_require_class($thing);
        return $thing->new;
    }

    croak "'$label' must be a class name, [class => \@args], or an object, not a " . ref($thing);
}

sub _require_class ($self, $class) {
    (my $file = $class) =~ s{::}{/}g;
    require "$file.pm";
    return;
}

=over 4

=item $self->_run_child($guard, $out_w, $err_w)

Child-side bootstrap: replace STDOUT / STDERR with the mixed-mode pipe
writers, apply the caller's C<env> overrides, mark the environment so a
Test2 stream formatter recognises it is inside a collector, and for test
jobs select that formatter via C<T2_FORMATTER> and place the process in a
fresh process group. The harness's own variables are set after the caller's
C<env> so they always win. Finally either C<exec> the requested command or
invoke the callback.

=back

=cut

sub _run_child ($self, $guard, $out_w, $err_w) {
    $out_w->blocking(1);
    $err_w->blocking(1);

    swap_io(\*STDOUT, $out_w->wh);
    swap_io(\*STDERR, $err_w->wh);

    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    if (my $env = $self->{+CHILD_ENV}) {
        $ENV{$_} = $env->{$_} for keys %$env;
    }

    $ENV{T2_HARNESS2_PIPE_COUNT} = 2;

    # Test jobs run Test2; point Test2::API at our stream formatter (it
    # prepends "Test2::Formatter::" to the value) and place them in a fresh
    # process group so the test cannot signal the collector tree.
    if ($self->{+IS_TEST}) {
        $ENV{T2_FORMATTER} = 'Stream2';

        # Stream2 turns in-subtest prints/warnings into events by default; set
        # this only when the caller pinned io_events explicitly (1 forces on, 0
        # forces off), otherwise leave the child's default in place.
        $ENV{T2_HARNESS2_IO_EVENTS} = $self->{+IO_EVENTS} ? 1 : 0
            if defined $self->{+IO_EVENTS};

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
events through the parser, route each through the processor chain, write to
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
    return undef unless HAVE_BSD_RESOURCE;

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
verbatim writing. Returns C<undef> (with a warning) on a decode failure. When
the event carries a C<control> facet naming an C<encoding>, that becomes the
encoding for subsequent raw lines.

=item $text = $self->_decode_line($text)

Decode a raw stream line through C<Encode::decode> using the current
C<encoding>. A no-op (returns the bytes unchanged) when no encoding is set or
the decode fails.

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
        $data = $self->_decode_line($data);
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

    my $event = $self->{+PARSER}->parse_io(
        stream => $stream,
        event  => $decoded,
        (defined $extra->{compressed} ? (compressed => $extra->{compressed}) : ()),
    );

    # A child can switch the encoding of its raw output mid-stream by emitting
    # a control facet carrying the new encoding; honor it for later lines.
    if ($event) {
        my $ctrl = $event->facet_data->{control};
        $self->{+ENCODING} = $ctrl->{encoding} if $ctrl && $ctrl->{encoding};
    }

    return $event;
}

sub _decode_line ($self, $text) {
    my $enc = $self->{+ENCODING} or return $text;

    require Encode;
    my $decoded;
    my $ok  = eval { $decoded = Encode::decode($enc, $text); 1 };
    my $err = $@;
    warn "decode($enc) of stream line failed: $err\n" unless $ok;

    return $ok ? $decoded : $text;
}

sub _is_sync_marker ($self, $data) {
    return $data =~ m/\A\s*\[/ ? 1 : 0;
}

sub _handle_direct ($self, $stream, $type, $data, $extra) {
    if ($type eq 'line') {
        chomp $data;
        $data = $self->_decode_line($data);
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

Route one event through the optional processor and hand each resulting event
to the recorder. The recorder owns the on-disk format (and the
C<compressed_form> fast path).

=back

=cut

sub _dispatch_event ($self, $event) {
    my @events = ($event);

    for my $proc (@{$self->{+PROCESSORS}}) {
        my @next;
        for my $in (@events) {
            my @out;
            warn "processor process_event failed: $@\n"
                unless eval { @out = $proc->process_event($in); 1 };

            push @next => @out;
        }
        @events = @next;
    }

    my $recorder = $self->{+RECORDER} or return;
    for my $e (@events) {
        warn "recorder record_event failed: $@\n"
            unless eval { $recorder->record_event($e); 1 };
    }

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
dispatch it through the pipeline, and finalize the recorder. The event
carries the decoded wait status (C<sig> / C<err> / C<dmp> / C<all>), the
launch and reap stamps (C<start_stamp> / C<stamp>), any C<orphaned> /
C<timed_out> / C<parent_exited> flags, the child's CPU and wall-clock timing,
and -- when L<BSD::Resource> is available -- its peak memory. All of these are deduced by the time the child is reaped, so they
ride on the single exit event rather than separate events.

=item $facet = $self->_exit_facet

Assemble the C<harness_process_exit> facet hash described above.

=back

=cut

sub _finalize ($self) {
    my $event = Test2::Harness2::Event->new(
        facet_data => {harness_process_exit => $self->_exit_facet},
    );
    $self->_dispatch_event($event);

    my $recorder = $self->{+RECORDER} or return;
    warn "recorder finalize failed: $@\n" unless eval { $recorder->finalize; 1 };
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
        (defined $self->{+FORK_STAMP} ? (start_stamp   => $self->{+FORK_STAMP}) : ()),
        ($self->{+ORPHANED}           ? (orphaned      => 1)                    : ()),
        ($self->{+TIMED_OUT}          ? (timed_out     => $self->{+TIMED_OUT})  : ()),
        ($self->{+PARENT_EXITED}      ? (parent_exited => 1)                    : ()),
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

=over 4

=item $info = $self->_build_info

Assemble the info hashref L</collect> returns from the collector's post-run
state: the decoded exit status, any orphan / timeout / parent-exit flag, and
the processor's C<final_state> when it exposes one.

=item $class->_run_spawned(\%args)

Child side of L</spawn_collector>: construct and run a collector, then
C<_exit> with the code from L</_spawn_exit_code>. Never returns.

=item _spawn_exit_code

=item $code = $class->_spawn_exit_code($info)

Map a L</collect> info hashref to a process exit code: C<0> when the verdict
passed (or the child exited cleanly with no verdict), C<1> otherwise.

=item %args = $class->_normalize_args(%args)

Translate the functional interface's C<exec> / C<run> argument names to the
constructor's C<exec_command> / C<run_sub> attributes.

=back

=cut

sub _build_info ($self) {
    my $px = parse_exit($self->{+WAIT_STATUS} // 0);

    my %info = (exit => {%$px});

    $info{exit}{orphaned}      = 1                   if $self->{+ORPHANED};
    $info{exit}{timed_out}     = $self->{+TIMED_OUT} if $self->{+TIMED_OUT};
    $info{exit}{parent_exited} = 1                   if $self->{+PARENT_EXITED};

    for my $processor (@{$self->{+PROCESSORS}}) {
        next unless $processor->can('final_state');
        $info{final_state} = $processor->final_state;
    }

    return \%info;
}

sub _run_spawned ($class, $args) {
    my $self = $class->new(%$args);
    $self->run_collector;
    POSIX::_exit($class->_spawn_exit_code($self->_build_info));
}

sub _normalize_args ($class, %args) {
    $args{exec_command} = delete $args{exec} if exists $args{exec};
    $args{run_sub}      = delete $args{run}  if exists $args{run};
    $args{child_env}    = delete $args{env}  if exists $args{env};
    return %args;
}

sub _spawn_exit_code ($class, $info) {
    if (my $fs = $info->{final_state}) {
        return $fs->{pass} ? 0 : 1;
    }

    return $info->{exit}{err} ? 1 : 0;
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
