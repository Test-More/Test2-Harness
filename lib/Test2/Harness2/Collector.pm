package Test2::Harness2::Collector;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Config;
use POSIX qw/:sys_wait_h setpgid/;
use Time::HiRes qw/time sleep/;
use Scalar::Util qw/blessed/;
use Scope::Guard ();
use IO::Handle;
use Atomic::Pipe;

use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Event;
use Test2::Harness2::Collector::FileLineReader;
use Test2::Harness2::Collector::Handle;
use Test2::Harness2::Util qw/mod2file parse_exit/;
use Test2::Harness2::Util::JSON qw/encode_json encode_json_file decode_json/;
use Test2::Harness2::Util::IPC qw/pid_is_running set_procname swap_io/;
use Test2::Harness2::Util::HashBase qw{
    <launch
    <new_pgroup
    <env_vars
    <out_fh
    <err_fh
    <child_pid
    <auditor
    <parser
    <loggers
    <parent_pids
    <kill_timeout

    +_started
    <_owns_child

    +_event_loggers
    +_loggers_spec
    +_auditor_spec
    +_failing_notified
    +_child_exit
};

use constant IS_WIN32 => $^O eq 'MSWin32';

sub init {
    my $self = shift;

    # Map spec constructor names to internal attribute names so callers can
    # use the natural names from the spec (stdout, stderr, pid, env) even
    # though HashBase cannot use those as constants due to Perl reserved words.
    $self->{+OUT_FH}    //= delete $self->{stdout} if exists $self->{stdout};
    $self->{+ERR_FH}    //= delete $self->{stderr} if exists $self->{stderr};
    $self->{+CHILD_PID} //= delete $self->{pid}    if exists $self->{pid};
    $self->{+ENV_VARS}  //= delete $self->{env}    if exists $self->{env};

    $self->{+KILL_TIMEOUT} //= 15;
    $self->{+ENV_VARS}     //= {};
    $self->{+NEW_PGROUP}   //= 0;

    $self->_normalize_loggers();
    $self->_normalize_auditor();

    my $has_launch = defined $self->{+LAUNCH};
    my $has_stdio  = defined($self->{+OUT_FH}) || defined($self->{+ERR_FH});

    croak "Must specify either 'launch' or 'stdout'/'stderr', not both"
        if $has_launch && $has_stdio;

    croak "Must specify either 'launch' or 'stdout'/'stderr'"
        unless $has_launch || $has_stdio;

    # Normalize launch to arrayref
    $self->{+LAUNCH} = [$self->{+LAUNCH}] if $has_launch && !ref($self->{+LAUNCH});

    # Open string paths for file-based handle input
    if ($has_stdio) {
        for my $attr (+OUT_FH, +ERR_FH) {
            next unless defined $self->{$attr};
            next if ref $self->{$attr};

            # It's a string path -- open it
            my $path = $self->{$attr};
            open(my $fh, '<', $path) or croak "Could not open '$path': $!";
            $self->{$attr} = $fh;
        }
    }

    # Default parser -- only needed when something will consume events.
    # Skip the default when there are no loggers and no auditor; user may
    # still pass one explicitly, which will be honored.
    $self->{+PARSER} //= 'Test2::Harness2::Collector::Parser::IOParser'
        if @{$self->{+LOGGERS}} || $self->{+AUDITOR};

    # Load parser class if it's a class name
    require(mod2file($self->{+PARSER}))
        if defined($self->{+PARSER}) && !ref $self->{+PARSER};
}

sub _load_logger_class {
    my ($class) = @_;
    my $file = mod2file($class);
    return if $INC{$file};
    no strict 'refs';
    return if %{"${class}::"};
    require $file;
}

sub _spec_class {
    my ($spec) = @_;

    return ref($spec) if blessed($spec);
    return $spec->[0] if ref($spec) eq 'ARRAY';
    return $spec      if !ref($spec);
    return undef;
}

# Validates a single spec for blessed/arrayref/string shape, loads the class
# (for non-blessed forms), and verifies it implements $role at the class level.
# Returns nothing; croaks on any problem.
sub _validate_spec {
    my ($spec, $kind, $role) = @_;

    if (blessed($spec)) {
        croak ucfirst($kind) . " '" . ref($spec) . "' does not implement $role"
            unless $spec->DOES($role);
        return;
    }

    my $class;
    if (ref($spec) eq 'ARRAY') {
        $class = $spec->[0];
        croak ucfirst($kind) . " arrayref must begin with a class name"
            unless defined($class) && !ref($class);
    }
    elsif (!ref($spec)) {
        $class = $spec;
    }
    else {
        croak "Invalid $kind specification: " . ref($spec);
    }

    _load_logger_class($class);

    croak ucfirst($kind) . " '$class' does not implement $role"
        unless $class->DOES($role);
}

# Pure validation: confirm each entry is a well-formed spec whose class
# implements the logger role. Constructors are NOT invoked here -- the actual
# instances are built lazily in _instantiate_loggers, which runs in the
# collector child only. This avoids opening files or other side effects in the
# parent that would then be duplicated across the fork/spawn boundary.
sub _normalize_loggers {
    my $self = shift;

    my $loggers = $self->{+LOGGERS} //= [];

    croak "'loggers' must be an arrayref" unless ref($loggers) eq 'ARRAY';

    my $role = 'Test2::Harness2::Role::Collector::Logger';

    for my $item (@$loggers) {
        _validate_spec($item, 'logger', $role);
    }

    # depends_on is a class method on the logger role with a default of (),
    # so we can resolve dependencies without instantiating.
    my %have = map { _spec_class($_) => 1 } @$loggers;
    for my $item (@$loggers) {
        my $class = _spec_class($item);
        for my $dep ($class->depends_on) {
            next if $have{$dep};
            croak "Logger '$class' requires logger '$dep', but it is not present";
        }
    }

    # Preserve original spec list for later serialization / instantiation.
    $self->{+_LOGGERS_SPEC} = [@$loggers];
}

sub _normalize_auditor {
    my $self = shift;

    my $spec = $self->{+AUDITOR};
    return unless defined $spec;

    _validate_spec($spec, 'auditor', 'Test2::Harness2::Role::Auditor');

    $self->{+_AUDITOR_SPEC} = $spec;
}

# Build instances from the spec list. Called from _run_collector so that only
# the collector child process constructs loggers/auditor objects -- the parent
# never opens those file handles, sockets, etc.
sub _instantiate_loggers {
    my $self = shift;

    my $specs = $self->{+_LOGGERS_SPEC} //= [];

    my @instances;
    for my $item (@$specs) {
        if (blessed($item)) {
            push @instances => $item;
        }
        elsif (ref($item) eq 'ARRAY') {
            my ($class, @args) = @$item;
            push @instances => $class->new(@args);
        }
        else {
            push @instances => $item->new();
        }
    }

    $self->{+LOGGERS} = \@instances;
}

sub _instantiate_auditor {
    my $self = shift;

    my $spec = $self->{+_AUDITOR_SPEC};
    return unless defined $spec;

    my $inst;
    if (blessed($spec)) {
        $inst = $spec;
    }
    elsif (ref($spec) eq 'ARRAY') {
        my ($class, @args) = @$spec;
        $inst = $class->new(@args);
    }
    else {
        $inst = $spec->new();
    }

    $self->{+AUDITOR} = $inst;
}

sub spawn {
    my ($class, %params) = @_;
    my $self = $class->new(%params);

    # start() replaces $_[0] with a handle in the parent (see below), so this
    # local $self becomes the handle on success.
    $self->start();

    return $self;
}

sub start {
    my ($self) = @_;

    croak "Collector already started" if $self->{+_STARTED};
    $self->{+_STARTED} = 1;

    my $pid = $self->_spawn_collector();

    # In the child of a fork, _spawn_collector exits before returning here.
    # Defensive: if we ever do return in the child, blow up loudly rather
    # than continuing the caller's code path.
    return unless defined $pid;

    # Parent: replace the caller's collector reference with a handle so the
    # heavyweight Collector instance (with its loggers, auditor, parser, and
    # pipe machinery) is not kept alive in the parent.
    $_[0] = Test2::Harness2::Collector::Handle->new(pid => $pid);

    return $pid;
}

sub _spawn_collector {
    my $self = shift;

    return $self->_spawn_collector_win32() if IS_WIN32;

    my $pid = fork() // die "Failed to fork collector: $!";

    # Parent
    return $pid if $pid;

    # Child -- never return from this scope. The Scope::Guard makes a runaway
    # control flow loud (POSIX::_exit(255)) instead of letting the caller's
    # code resume in a process it never expected to touch.
    my $guard = Scope::Guard->new(sub { POSIX::_exit(255) });

    my $ok  = eval { $self->_run_collector(); 1 };
    my $err = $@;

    $self->_emit_collector_error("Collector process died: $err") unless $ok;

    $guard->dismiss;
    $self->_exit_mirroring_child($ok);
}

sub _spawn_collector_win32 {
    my $self = shift;

    my $has_launch = defined $self->{+LAUNCH};

    unless ($has_launch) {
        # Pipe-based and file-based callers pass in file handles which
        # cannot be serialized to a new process, so run the collector inline.
        warn "Collector died: $@" unless eval { $self->_run_collector(); 1 };
        return undef;
    }

    # Launch mode: serialize the constructor args to a temp JSON file
    # and spawn a new perl process that loads this module and runs
    # the collector loop, same pattern as the old start_collected_process.
    my %params = (
        launch       => $self->{+LAUNCH},
        env_vars     => $self->{+ENV_VARS},
        kill_timeout => $self->{+KILL_TIMEOUT},
    );

    $params{parent_pids} = $self->{+PARENT_PIDS} if $self->{+PARENT_PIDS};

    # Parser must be a class name for the spawned process to load it
    my $parser = $self->{+PARSER};
    if (ref $parser) {
        $params{parser} = ref($parser);
    }
    else {
        $params{parser} = $parser;
    }

    # Loggers must be specified as class names or [class, @args] arrayrefs on
    # Windows, since blessed instances cannot be serialized to the spawned
    # collector process.
    for my $item (@{$self->{+_LOGGERS_SPEC}}) {
        croak "Blessed logger instances cannot be passed to a Windows collector; use class name or [class, \@args] form"
            if blessed($item);
    }
    $params{loggers} = $self->{+_LOGGERS_SPEC};

    # Auditor follows the same constraint -- class name or [class, %args]
    # arrayref only on Windows, since blessed instances cannot be serialized.
    if (defined $self->{+_AUDITOR_SPEC}) {
        croak "Blessed auditor instances cannot be passed to a Windows collector; use class name or [class, \@args] form"
            if blessed($self->{+_AUDITOR_SPEC});
        $params{auditor} = $self->{+_AUDITOR_SPEC};
    }

    my $json_file = encode_json_file(\%params);

    # Build the command: current perl, all @INC paths, load this module,
    # then run the collect_from_file() class method.
    my %seen;
    my @inc = grep { -d $_ && !$seen{$_}++ } @INC;

    my @cmd = (
        $^X,
        (map { "-I$_" } @inc),
        '-mTest2::Harness2::Collector',
        '-e', 'Test2::Harness2::Collector->collect_from_file($ARGV[0])',
        $json_file,
    );

    my $pid;
    my $ok  = eval { $pid = system 1, @cmd; 1 };
    my $err = $@;

    if (!$ok || !$pid || $pid < 0) {
        unlink($json_file);
        croak "Failed to spawn collector process: " . ($err || $!);
    }

    return $pid;
}

# Class method invoked by the spawned collector process on Windows.
# Reads constructor args from a JSON file, builds a new Collector
# (skipping the spawn step), and runs the collection loop directly.
sub collect_from_file {
    my ($class, $file) = @_;

    require Test2::Harness2::Util::JSON;
    my $params = Test2::Harness2::Util::JSON::decode_json_file($file, unlink => 1);

    my $self = $class->new(%$params);

    # Defensive scope guard: never let execution leak past this method in the
    # spawned process.
    my $guard = Scope::Guard->new(sub { POSIX::_exit(255) });

    my $ok  = eval { $self->_run_collector(); 1 };
    my $err = $@;

    $self->_emit_collector_error("Collector process died: $err") unless $ok;

    $guard->dismiss;
    $self->_exit_mirroring_child($ok);
}

sub _run_collector {
    my $self = shift;

    my ($child_pid, $out_r, $err_r);
    my $started_child = defined($self->{+LAUNCH}) || $self->{+_OWNS_CHILD};

    if (defined $self->{+LAUNCH}) {
        ($child_pid, $out_r, $err_r) = $self->_launch_child();
        $self->{+CHILD_PID} = $child_pid;
    }
    else {
        $child_pid = $self->{+CHILD_PID};

        # Wrap handles for the collection loop.
        # Pipe handles: wrap in Atomic::Pipe with mixed_data_mode.
        # Regular file handles: use a plain line-reader shim.
        # Fifo/pipe handles passed as file paths: also wrapped in Atomic::Pipe.
        $out_r = $self->_wrap_handle($self->{+OUT_FH}) if defined $self->{+OUT_FH};
        $err_r = $self->_wrap_handle($self->{+ERR_FH}) if defined $self->{+ERR_FH};
    }

    # Set process name
    $self->_set_procname($child_pid);

    # Setup signal handlers (block-local so they restore automatically when
    # _run_collector returns, including via die).
    my $got_signal;
    local $SIG{TERM} = sub { $got_signal = 'TERM' };
    local $SIG{INT}  = sub { $got_signal = 'INT' };

    # Build logger and auditor instances now, in the collector child process
    # only, so the parent never opens those file handles / sockets / etc.
    $self->_instantiate_loggers();
    $self->_instantiate_auditor();

    # Start loggers and cache the event-logging subset
    $_->startup($self) for @{$self->{+LOGGERS}};
    $self->{+_EVENT_LOGGERS} = [grep { $_->log_events } @{$self->{+LOGGERS}}];

    # Instantiate parser. When there is no parser the collector still drains
    # the handles but discards the lines without constructing events.
    my $parser = $self->{+PARSER};
    $parser = $parser->new() if defined($parser) && !ref $parser;

    # Route collector-process warnings through the logger chain in addition to
    # the default STDERR print.  This captures warnings produced by auditors,
    # loggers, and the collector's own internal logic that would otherwise only
    # reach the calling terminal.  Child-process warnings already flow through
    # the stdout/stderr pipe to this process's parser chain, so no handler is
    # needed on the child side.  Use local so the handler is restored when
    # _run_collector returns (including via die).
    local $SIG{__WARN__} = sub {
        my ($msg) = @_;
        print STDERR $msg;

        my $ok = eval {
            my %harness;
            if ($parser) {
                $harness{run_id}  = $parser->run_id  if defined $parser->run_id;
                $harness{job_id}  = $parser->job_id  if defined $parser->job_id;
                $harness{job_try} = $parser->job_try if defined $parser->job_try;
            }

            my $event = Test2::Harness2::Event->new(
                event_id   => gen_uuid(),
                stamp      => time,
                facet_data => {
                    (%harness ? (harness => \%harness) : ()),
                    info => [{tag => 'WARNING', details => $msg, debug => 1}],
                },
            );
            $self->_process_event($event);
            1;
        };
        # Use print STDERR rather than warn to avoid re-entering this handler.
        print STDERR "Failed to log warning event: $@\n" unless $ok;
    };

    # Main collection loop
    my $child_exited = 0;
    my $child_exit   = undef;
    my $stdout_eof   = defined($out_r) ? 0 : 1;
    my $stderr_eof   = defined($err_r) ? 0 : 1;

    # Merged if same handle object or err not provided
    my $merge_outputs = defined($out_r) && defined($err_r) && "$out_r" eq "$err_r";
    $stderr_eof = 1 if $merge_outputs;

    # Ordering buffer. Atomic::Pipe streams may interleave plain lines with
    # JSON-burst events on STDOUT, and the Test2 Stream formatter sends a
    # sync marker {"event_id":...} on STDERR each time it writes an event on
    # STDOUT. We buffer both streams until we have seen the matching
    # event_id on both sides (or just once when the streams are merged) and
    # then flush in order, so stdout/stderr text keeps its relative
    # ordering against the events. `saw_event` latches once we see any
    # JSON-burst so the "pure text" eager-flush path stops firing even after
    # we have pruned flushed event_ids out of `seen`.
    my $buffer = {seen => {}, saw_event => 0, stdout => [], stderr => []};

    my $draining = 0;    # Set when we got a signal/parent-gone and are finishing up

    while (1) {
        my $ok = eval {
            # Check for signal - kill child but keep draining handles
            if ($got_signal && !$draining) {
                $self->_kill_child($child_pid) if $child_pid;
                $draining     = 1;
                $child_exited = 1;
            }

            # Check parent pids
            if (!$draining && $self->{+PARENT_PIDS} && @{$self->{+PARENT_PIDS}}) {
                my $parent_gone = 0;
                for my $ppid (@{$self->{+PARENT_PIDS}}) {
                    unless (pid_is_running($ppid)) {
                        $parent_gone = 1;
                        last;
                    }
                }
                if ($parent_gone) {
                    $self->_kill_child($child_pid) if $child_pid;
                    $draining     = 1;
                    $child_exited = 1;
                }
            }

            # Read stdout
            unless ($stdout_eof) {
                for my $item ($self->_read_handle($out_r)) {
                    if (!defined $item) {
                        $stdout_eof = 1;
                        last;
                    }
                    next unless $parser;
                    $self->_ingest_item($buffer, 'stdout', $item, $merge_outputs, $parser);
                }
            }

            # Read stderr
            unless ($stderr_eof) {
                for my $item ($self->_read_handle($err_r)) {
                    if (!defined $item) {
                        $stderr_eof = 1;
                        last;
                    }
                    next unless $parser;
                    $self->_ingest_item($buffer, 'stderr', $item, $merge_outputs, $parser);
                }
            }

            # Check if child has exited (only if we started it via waitpid)
            if ($child_pid && $started_child && !$child_exited) {
                my $rv = waitpid($child_pid, WNOHANG);
                if ($rv == $child_pid) {
                    $child_exited = 1;
                    $child_exit   = $?;
                }
            }

            # For externally-managed pids we can't waitpid, but we can still
            # notice they are gone via pid_is_running. Exit status is not
            # available in this path; that requires the IPC channel.
            if ($child_pid && !$started_child && !$child_exited) {
                $child_exited = 1 unless pid_is_running($child_pid);
            }

            1;
        };
        my $err = $@;

        unless ($ok) {
            $self->_emit_collector_error($err);

            # Terminate the child and bail out of the loop
            $self->_kill_child($child_pid) if $child_pid && $started_child;
            last;
        }

        # Check if we're done
        if ($stdout_eof && $stderr_eof) {
            # Drain any remaining child exit if we started it
            if ($child_pid && $started_child && !$child_exited) {
                my $rv = waitpid($child_pid, 0);
                $child_exit   = $? if $rv == $child_pid;
                $child_exited = 1;
            }
            last;
        }
    }

    # Flush anything still sitting in the ordering buffer (items that never
    # got a matching sync marker).
    $self->_flush_buffer($buffer, $parser) if $parser;

    # Write exit event if we have an exit code, and stash it so the spawning
    # method can mirror the child's exit when it terminates the collector.
    if (defined $child_exit) {
        $self->{+_CHILD_EXIT} = $child_exit;

        my $exit_event = Test2::Harness2::Event->new(
            event_id   => gen_uuid(),
            stamp      => time,
            facet_data => {
                harness_process_exit => parse_exit($child_exit),
            },
        );
        $self->_process_event($exit_event);
    }

    # Shut down loggers
    $_->shutdown($self) for @{$self->{+LOGGERS}};

    return 1;
}

sub _set_procname {
    my $self = shift;
    my ($child_pid) = @_;

    my @parts = ('Collector');

    push @parts => $child_pid if $child_pid;

    if ($self->{+LAUNCH}) {
        my $cmd = ref($self->{+LAUNCH}) ? join(' ', @{$self->{+LAUNCH}}) : $self->{+LAUNCH};
        push @parts => $cmd;
    }
    elsif (defined $self->{+OUT_FH} || defined $self->{+ERR_FH}) {
        # Try to show file info
        my @files;
        if (!ref($self->{+OUT_FH}) && defined $self->{+OUT_FH}) {
            push @files => "out=$self->{+OUT_FH}";
        }
        if (!ref($self->{+ERR_FH}) && defined $self->{+ERR_FH}) {
            push @files => "err=$self->{+ERR_FH}";
        }
        push @parts => @files if @files;
    }

    set_procname(set => [join(' - ', @parts)]);
}

sub _launch_child {
    my $self = shift;

    my ($out_r, $out_w) = Atomic::Pipe->pair(mixed_data_mode => 1);
    my ($err_r, $err_w) = Atomic::Pipe->pair(mixed_data_mode => 1);

    # Save copies of the original STDOUT/STDERR before redirecting; restored
    # by both platform-specific launchers in the parent path.
    open(my $orig_stdout, '>&', \*STDOUT) or croak "Could not clone STDOUT: $!";
    open(my $orig_stderr, '>&', \*STDERR) or croak "Could not clone STDERR: $!";

    my $pid =
        IS_WIN32
        ? $self->_launch_child_win32($out_r, $out_w, $err_r, $err_w, $orig_stdout, $orig_stderr)
        : $self->_launch_child_unix($out_r, $out_w, $err_r, $err_w, $orig_stdout, $orig_stderr);

    # Parent (both platforms) - close write ends so reads get EOF.
    $out_w->close();
    $err_w->close();

    close($orig_stdout);
    close($orig_stderr);

    return ($pid, $out_r, $err_r);
}

# Environment additions injected into every collector-launched child so
# Test2::Formatter::Stream2 knows it is running under a collector
# (and how many mixed-mode pipes the collector is reading from).
sub _child_env_overrides {
    my $self = shift;
    return (
        %{$self->{+ENV_VARS}},
        T2_HARNESS2_PIPE_COUNT => 2,
    );
}

sub _launch_child_unix {
    my $self = shift;
    my ($out_r, $out_w, $err_r, $err_w, $orig_stdout, $orig_stderr) = @_;

    my $cmd = $self->{+LAUNCH};

    my $pid = fork() // die "Failed to fork child process: $!";

    if (!$pid) {
        # Child process
        $out_r->close();
        $err_r->close();

        swap_io(\*STDOUT, $out_w->wh);
        swap_io(\*STDERR, $err_w->wh);
        STDOUT->autoflush(1);
        STDERR->autoflush(1);

        close($orig_stdout);
        close($orig_stderr);

        # Optionally put the child in a brand-new process group so its signal
        # handling is isolated from the harness. Enabled only when the caller
        # sets new_pgroup => 1 (the harness does so for test launches). This
        # prevents a test doing `kill 'TERM', 0` from taking down the harness.
        if ($self->{+NEW_PGROUP}) {
            POSIX::setpgid(0, 0) or warn "setpgid(0,0) failed: $!";
        }

        my %env = $self->_child_env_overrides;
        local @ENV{keys %env} = values %env;
        exec(@$cmd) or croak "Failed to exec '@$cmd': $!";
    }

    # Parent: restore STDOUT/STDERR so collector diagnostics still go to the
    # real terminal.
    open(STDOUT, '>&', $orig_stdout) or croak "Could not restore STDOUT: $!";
    open(STDERR, '>&', $orig_stderr) or croak "Could not restore STDERR: $!";

    return $pid;
}

sub _check_new_pgroup_supported_on_win32 {
    my $self = shift;

    # new_pgroup is not yet wired up on Windows. The spec calls for
    # Win32::Job (AssignProcessToJobObject + TerminateJobObject) to
    # replace system(1, @cmd) with an atomically-terminable spawn path.
    # Until that work lands, fail fast rather than silently ignoring the
    # isolation request -- the harness relies on it for Invariant 1.
    if ($self->{+NEW_PGROUP}) {
        croak "new_pgroup => 1 is not yet supported on Windows; install Win32::Job " . "and implement the Collector Win32 launch path that uses it";
    }
}

sub _launch_child_win32 {
    my $self = shift;
    my ($out_r, $out_w, $err_r, $err_w, $orig_stdout, $orig_stderr) = @_;

    $self->_check_new_pgroup_supported_on_win32();

    my $cmd = $self->{+LAUNCH};

    # On Windows there is no fork. Redirect STDOUT/STDERR to the pipe write
    # ends, spawn via system(1, @cmd) (P_NOWAIT) which returns the child PID
    # immediately, then restore handles.
    swap_io(\*STDOUT, $out_w->wh);
    swap_io(\*STDERR, $err_w->wh);
    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    my $pid;
    my $ok;
    {
        my %env = $self->_child_env_overrides;
        local @ENV{keys %env} = values %env;
        $ok = eval { $pid = system 1, @$cmd; 1 };
    }
    my $err = $@;

    # Restore STDOUT/STDERR immediately after spawn.
    open(STDOUT, '>&', $orig_stdout) or croak "Could not restore STDOUT: $!";
    open(STDERR, '>&', $orig_stderr) or croak "Could not restore STDERR: $!";

    croak "Failed to spawn '@$cmd': " . ($err || $!)
        if !$ok || !$pid || $pid < 0;

    return $pid;
}

sub _wrap_handle {
    my $self = shift;
    my ($handle) = @_;

    # Already an Atomic::Pipe object
    return $handle if blessed($handle) && $handle->isa('Atomic::Pipe');

    # Pipe or fifo filehandle -- wrap in Atomic::Pipe with mixed_data_mode
    if (-p $handle) {
        my $ap = Atomic::Pipe->from_fh('<&', $handle);
        $ap->set_mixed_data_mode();
        return $ap;
    }

    # Regular file handle -- use plain line-reader shim, no Atomic::Pipe.
    return Test2::Harness2::Collector::FileLineReader->new($handle);
}

sub _read_handle {
    my $self = shift;
    my ($handle) = @_;

    # Atomic::Pipe handles -- return [type, data] tuples so the caller can
    # distinguish atomic message bursts (JSON events) from plain lines.
    if (blessed($handle) && $handle->isa('Atomic::Pipe')) {
        my @items;

        while (1) {
            my ($type, $data) = $handle->get_line_burst_or_data();
            last unless defined $type;
            push @items => [$type, $data];
        }

        push @items => undef if $handle->eof();

        return @items;
    }

    # FileLineReader already emits [line => $data] tuples and a trailing
    # undef EOF sentinel, so pass its output through unchanged.
    return $handle->read_lines();
}

sub _ingest_item {
    my $self = shift;
    my ($buffer, $stream, $item, $merge_outputs, $parser) = @_;

    my ($type, $data) = @$item;
    my $stamp = time;

    if ($type eq 'message') {
        # Atomic JSON burst. On STDOUT this is a full event; on STDERR it is
        # a sync marker whose event_id tells us that the matching STDOUT
        # event (and any STDERR context around it) can now be drained.
        my $decoded;
        unless (eval { $decoded = decode_json($data); 1 }) {
            my $err = $@;
            $self->_emit_collector_error(
                "Failed to decode JSON burst on $stream: $err",
                invalid_json => $data,
            );
            return;
        }

        push @{$buffer->{$stream}} => [$stamp, message => $decoded];

        my $event_id = ref($decoded) eq 'HASH' ? $decoded->{event_id} : undef;
        return unless defined $event_id;

        $buffer->{saw_event} = 1;

        my $count     = ++$buffer->{seen}{$event_id};
        my $threshold = $merge_outputs ? 1 : 2;

        $self->_flush_buffer($buffer, $parser, to => $event_id)
            if $count >= $threshold;

        return;
    }

    # Plain line. Atomic::Pipe delivers lines with the trailing newline
    # still attached in mixed_data_mode; strip it for consistency with
    # the FileLineReader path (which chomps).
    chomp $data;
    push @{$buffer->{$stream}} => [$stamp, line => $data];

    # Until we have seen any event there is nothing to synchronize against
    # -- flush eagerly so pure-text processes don't stall. We can't rely on
    # keys %{seen} here because flush_buffer prunes event_ids as they drain.
    $self->_flush_buffer($buffer, $parser) unless $buffer->{saw_event};
}

sub _flush_buffer {
    my $self = shift;
    my ($buffer, $parser, %params) = @_;

    my $to = $params{to};

    for my $stream (qw/stderr stdout/) {
        my $queue = $buffer->{$stream};
        while (my $entry = shift @$queue) {
            my ($stamp, $kind, $val) = @$entry;

            if ($kind eq 'message') {
                if ($stream eq 'stdout') {
                    # A real event arrived via a burst -- feed it through
                    # the parser so the harness facet still gets populated.
                    my $event = $parser->parse_io(
                        stream => $stream,
                        event  => $val,
                        stamp  => $stamp,
                    );
                    $self->_process_event($event) if $event;
                }
                # STDERR messages are sync markers only; nothing to emit.

                # Drop event_ids we've drained so `seen` can't grow without
                # bound across a long-running process.
                if (ref($val) eq 'HASH' && defined(my $eid = $val->{event_id})) {
                    delete $buffer->{seen}{$eid};
                    last if defined($to) && $eid eq $to;
                }
            }
            else {
                my $event = $parser->parse_io(
                    stream => $stream,
                    line   => $val,
                    stamp  => $stamp,
                );
                $self->_process_event($event) if $event;
            }
        }
    }
}

sub _emit_collector_error {
    my $self = shift;
    my ($msg, %extra) = @_;

    my $ok = eval {
        my $event = Test2::Harness2::Event->new(
            event_id   => gen_uuid(),
            stamp      => time,
            facet_data => {
                errors => [{
                    tag     => 'COLLECTR',
                    details => "Collector exception: $msg",
                    fail    => 1,
                    %extra,
                }],
            },
        );
        $self->_process_event($event);
        1;
    };
    return if $ok;

    warn "Collector exception: $msg\n";
    warn "Additionally, failed to log collector error: $@\n";
}

sub _process_event {
    my $self = shift;
    my ($event) = @_;

    return unless $event;

    my @events;
    if (my $auditor = $self->{+AUDITOR}) {
        @events = $auditor->audit_event($event);

        if (!$self->{+_FAILING_NOTIFIED} && $auditor->failing) {
            $_->failing(1) for @{$self->{+LOGGERS}};
            $self->{+_FAILING_NOTIFIED} = 1;
        }
    }
    else {
        @events = ($event);
    }

    my $loggers = $self->{+_EVENT_LOGGERS} or return;
    return unless @$loggers;

    for my $e (@events) {
        next unless $e;
        $_->log_event($e) for @$loggers;
    }
}

# Terminate the collector process. Three cases drive the chosen exit:
#
#   * Collector itself failed (the eval { _run_collector } died, $collector_ok
#     is false): _exit(255). Distinct from any child status so callers can
#     tell a collector bug apart from a test failure.
#
#   * We have the watched child's wait-status (launch and interpose modes,
#     where we own waitpid): mirror it. If the child died from a signal we
#     restore that signal's default disposition and re-raise it, so the
#     collector's wait-status carries the same signal the test process did.
#     Otherwise _exit with the child's exit code.
#
#   * No wait-status available (pipe mode with an externally-managed pid, or
#     pure file-input mode): we cannot mirror an exit. Fall back to the
#     auditor's verdict -- exit 1 if the auditor saw a failure on the child
#     being collected, 0 for normal operation. With no auditor, exit 0.
sub _exit_mirroring_child {
    my $self = shift;
    my ($collector_ok) = @_;

    POSIX::_exit(255) unless $collector_ok;

    if (defined(my $child_exit = $self->{+_CHILD_EXIT})) {
        my $codes = parse_exit($child_exit);

        if (my $sig = $codes->{sig}) {
            my @names = split ' ', $Config{sig_name};
            if (my $name = $names[$sig]) {
                $SIG{$name} = 'DEFAULT';
                kill($name => $$);
            }

            # If the signal didn't terminate us, fall back to the shell
            # convention of 128 + signal number.
            POSIX::_exit(128 + $sig);
        }

        POSIX::_exit($codes->{err} // 0);
    }

    # No wait-status. Use the auditor's verdict if we have one.
    POSIX::_exit($self->{+_FAILING_NOTIFIED} ? 1 : 0);
}

sub _kill_child {
    my $self = shift;
    my ($pid) = @_;

    croak "_kill_child called without a pid" unless $pid;
    return                                   unless pid_is_running($pid);

    if (IS_WIN32) {
        # Windows perl does not have a useful SIGTERM; use SIGINT as the
        # graceful-shutdown signal there.
        kill('INT', $pid);
        waitpid($pid, 0);
        return $?;
    }

    # Unix: try TERM first, escalate to KILL after timeout
    kill('TERM', $pid);

    my $timeout = $self->{+KILL_TIMEOUT};
    my $start   = time;

    while (time - $start < $timeout) {
        my $rv = waitpid($pid, WNOHANG);
        return $? if $rv == $pid;
        sleep(0.1);
    }

    # Force kill
    kill('KILL', $pid);
    my $rv = waitpid($pid, 0);
    return $?;
}

sub interpose {
    my ($class, %params) = @_;

    croak "interpose() is a class method"           if ref $class;
    croak "interpose() is not supported on Windows" if IS_WIN32;

    ($params{out_r}, $params{out_w}) = Atomic::Pipe->pair(mixed_data_mode => 1);
    ($params{err_r}, $params{err_w}) = Atomic::Pipe->pair(mixed_data_mode => 1);

    open($params{orig_stdout}, '>&', \*STDOUT) or croak "Could not clone STDOUT: $!";
    open($params{orig_stderr}, '>&', \*STDERR) or croak "Could not clone STDERR: $!";

    my $pid = fork() // die "Failed to fork for interpose: $!";

    # Child resumes caller's execution path
    return $class->_interpose_child(\%params) unless $pid;

    # Parent becomes the collector and exits when done -- does not return
    $params{pid} = $pid;
    $class->_interpose_parent(\%params);
}

sub _interpose_parent {
    my ($class, $params) = @_;

    # Defensive scope guard: this method is the parent's whole life from the
    # interpose fork onward; never let execution leak past it.
    my $guard = Scope::Guard->new(sub { POSIX::_exit(255) });

    my $out_w       = delete $params->{out_w};
    my $err_w       = delete $params->{err_w};
    my $orig_stdout = delete $params->{orig_stdout};
    my $orig_stderr = delete $params->{orig_stderr};

    $out_w->close();
    $err_w->close();

    # Restore original stdout/stderr so the collector can still print
    # warnings/diagnostics to the real terminal.
    open(STDOUT, '>&', $orig_stdout) or croak "Could not restore STDOUT: $!";
    open(STDERR, '>&', $orig_stderr) or croak "Could not restore STDERR: $!";
    close($orig_stdout);
    close($orig_stderr);

    # Remap internal keys to spec names that init() expects
    $params->{stdout}        = delete $params->{out_r};
    $params->{stderr}        = delete $params->{err_r};
    $params->{_OWNS_CHILD()} = 1;

    my $self = $class->new(%$params);

    my $ok  = eval { $self->_run_collector(); 1 };
    my $err = $@;

    $self->_emit_collector_error("Collector (interpose) died: $err") unless $ok;

    $guard->dismiss;
    $self->_exit_mirroring_child($ok);
}

sub _interpose_child {
    my ($class, $params) = @_;

    $params->{out_r}->close();
    $params->{err_r}->close();

    swap_io(\*STDOUT, $params->{out_w}->wh);
    swap_io(\*STDERR, $params->{err_w}->wh);
    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    close($params->{orig_stdout});
    close($params->{orig_stderr});
}

1;
