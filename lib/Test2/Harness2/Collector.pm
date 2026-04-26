package Test2::Harness2::Collector;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Config;
use POSIX qw/:sys_wait_h setpgid/;
use Time::HiRes qw/time/;
use Scalar::Util qw/blessed/;
use Scope::Guard ();
use IO::Handle;
use IO::Select;
use Atomic::Pipe;
use Role::Tiny ();

use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Event;
use Test2::Harness2::Collector::FileLineReader;
use Test2::Harness2::Collector::Handle;
use Test2::Harness2::Util qw/load_module parse_exit tinysleep/;
use Test2::Harness2::Util::JSON qw/encode_json encode_json_file decode_json/;
use Test2::Harness2::Util::IPC qw/pid_is_running set_procname swap_io ipc_default_connect_args atomic_pipe_compression_args apply_atomic_pipe_compression/;

# This is the base class. Two subclasses add the test-vs-service
# divergent behaviour: Test2::Harness2::Collector::Test carries an
# auditor and derives its bus_id from job_id, while
# Test2::Harness2::Collector::Service skips the auditor machinery
# and derives its bus_id from the interposed service's bus name.
# The base class is instantiable (the auditor accessors default to
# undef / no-op) so generic collector behaviour can be exercised
# without picking a subclass.
use Object::HashBase qw{
    <launch
    <new_pgroup
    <env_vars
    <out_fh
    <err_fh
    <child_pid
    <parser
    <loggers
    <loggers_lookup
    <observers
    +_observers_spec
    <parent_pids
    <kill_timeout
    <logdir
    <service_name
    <run_id
    <job_id
    <job_try
    <is_run
    <ipcm_info
    <ipc_parent
    <ipc_run
    <ipc_harness
    <bus_id

    +_started
    <_owns_child

    +_event_loggers
    +_loggers_spec
    +_failing_notified
    <child_exit

    +_win32_job
    +_start_times
};

# Default auditor accessors for the base class. Test2::Harness2::Collector::Test
# overrides `auditor` via its own HashBase slot and replaces
# `_auditor_spec` / `_normalize_auditor` / `_instantiate_auditor` with
# working implementations.
sub auditor              { undef }
sub _auditor_spec        { undef }
sub _normalize_auditor   { }
sub _instantiate_auditor { }

# True only in the harness's own top-of-tree interpose collector,
# where ipc_harness points at the collector's own child (the harness
# service). End-of-life and logger-metadata sends that would normally
# target ipc_harness have nowhere useful to go in that case, and the
# child has usually already _exit()'d by the time the collector
# reaches EOF -- hitting the "Disconnected pipe" warn path. The
# Service::Harness subclass overrides this to 1; the send sites
# consult it to short-circuit self-addressed traffic.
sub is_harness_collector { 0 }

use Test2::Util qw/IS_WIN32/;

sub init {
    my $self = shift;

    croak "'ipcm_info' is a required attribute"
        unless defined $self->{+IPCM_INFO};

    # ipc_harness is the bus name of the main harness service; every
    # collector needs it so end-of-life messages land there regardless
    # of the collector's position in the service tree. ipc_parent is
    # the bus name of whatever service spawned this collector (for a
    # test-job collector: its RunService; for the harness interpose
    # collector: undef -- it has no parent service to notify). A
    # missing parent is valid; a missing harness is not.
    croak "'ipc_harness' is a required attribute"
        unless defined $self->{+IPC_HARNESS};

    # Map spec constructor names to internal attribute names so callers can
    # use the natural names from the spec (stdout, stderr, pid, env) even
    # though HashBase cannot use those as constants due to Perl reserved words.
    $self->{+OUT_FH}    //= delete $self->{stdout} if exists $self->{stdout};
    $self->{+ERR_FH}    //= delete $self->{stderr} if exists $self->{stderr};
    $self->{+CHILD_PID} //= delete $self->{pid}    if exists $self->{pid};
    $self->{+ENV_VARS}  //= delete $self->{env}    if exists $self->{env};

    $self->{+JOB_ID}  //= gen_uuid();
    $self->{+JOB_TRY} //= 0;

    $self->{+_START_TIMES} = [times()];

    $self->{+KILL_TIMEOUT} //= 15;
    $self->{+ENV_VARS}     //= {};
    $self->{+NEW_PGROUP}   //= 0;

    # Callers should pass bus_id explicitly (the harness-interpose
    # call site in particular cannot be derived from ipc_parent
    # because the harness has no parent service). When they do not,
    # fall back to the subclass's best-effort derivation.
    $self->{+BUS_ID} //= $self->_build_collector_bus_id;

    # Auditor first: loggers may need to consult it, and validation should run
    # in the same order as instantiation below.
    $self->_normalize_auditor();
    $self->_normalize_observers();
    $self->_normalize_loggers();

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
        if @{$self->{+LOGGERS}} || $self->auditor;

    # Load parser class if it's a class name
    load_module($self->{+PARSER})
        if defined($self->{+PARSER}) && !ref $self->{+PARSER};
}

sub _spec_class {
    my $class = shift;
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
    my $class = shift;
    my ($spec, $kind, $role) = @_;

    if (blessed($spec)) {
        croak ucfirst($kind) . " '" . ref($spec) . "' does not implement $role"
            unless Role::Tiny::does_role($spec, $role);
        return;
    }

    my $name;
    if (ref($spec) eq 'ARRAY') {
        $name = $spec->[0];
        croak ucfirst($kind) . " arrayref must begin with a class name"
            unless defined($name) && !ref($name);
    }
    elsif (!ref($spec)) {
        $name = $spec;
    }
    else {
        croak "Invalid $kind specification: " . ref($spec);
    }

    load_module($name);

    croak ucfirst($kind) . " '$name' does not implement $role"
        unless Role::Tiny::does_role($name, $role);
}

# Default observer spec accessor. Subclasses may override to install
# default observers (e.g. Collector::Test installs TestObserver).
sub _default_observers { () }

# Validate the observers spec list. Each entry must be a class name
# (or [class, @args] / blessed instance) implementing the Observer
# role. Like loggers, instances are built lazily in the collector
# child process via _instantiate_observers.
sub _normalize_observers {
    my $self = shift;

    my $observers = $self->{+OBSERVERS};
    if (!defined($observers)) {
        $observers = $self->{+OBSERVERS} = [$self->_default_observers];
    }

    croak "'observers' must be an arrayref" unless ref($observers) eq 'ARRAY';

    my $role = 'Test2::Harness2::Role::Collector::Observer';

    for my $item (@$observers) {
        $self->_validate_spec($item, 'observer', $role);
    }

    $self->{+_OBSERVERS_SPEC} = [@$observers];
}

# Build observer instances inside the collector child process. Mirrors
# _instantiate_loggers: blessed instances get identity / ipcm_info
# stamped on via setters; class / [class, @args] specs go through new()
# with the standard identity hash.
sub _instantiate_observers {
    my $self = shift;

    my $specs = $self->{+_OBSERVERS_SPEC} //= [];

    $self->{+OBSERVERS} = [];

    for my $item (@$specs) {
        my %identity = (
            run_id  => $self->{+RUN_ID},
            job_id  => $self->{+JOB_ID},
            job_try => $self->{+JOB_TRY},
        );

        my $inst;
        if (blessed($item)) {
            $item->set_process_info(%identity);
            $item->set_ipcm_info($self->{+IPCM_INFO});
            $item->set_auditor($self->auditor) if $self->auditor;
            $inst = $item;
        }
        elsif (ref($item) eq 'ARRAY') {
            my ($class, @args) = @$item;
            $inst = $class->new(
                %identity,
                ipcm_info => $self->{+IPCM_INFO},
                (defined $self->auditor ? (auditor => $self->auditor) : ()),
                @args,
            );
        }
        else {
            $inst = $item->new(
                %identity,
                ipcm_info => $self->{+IPCM_INFO},
                (defined $self->auditor ? (auditor => $self->auditor) : ()),
            );
        }

        push @{$self->{+OBSERVERS}} => $inst;
    }
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
        $self->_validate_spec($item, 'logger', $role);
    }

    # depends_on is a class method on the logger role with a default of (),
    # so we can resolve dependencies without instantiating.
    my %have = map { $self->_spec_class($_) => 1 } @$loggers;
    for my $item (@$loggers) {
        my $class = $self->_spec_class($item);
        for my $dep ($class->depends_on) {
            next if $have{$dep};
            croak "Logger '$class' requires logger '$dep', but it is not present";
        }
    }

    # Preserve original spec list for later serialization / instantiation.
    $self->{+_LOGGERS_SPEC} = [@$loggers];
}

# Build instances from the spec list. Called from _run_collector so that only
# the collector child process constructs loggers/auditor objects -- the parent
# never opens those file handles, sockets, etc.
sub _instantiate_loggers {
    my $self = shift;

    my $specs = $self->{+_LOGGERS_SPEC} //= [];

    $self->{+LOGGERS}        = [];
    $self->{+LOGGERS_LOOKUP} = {};

    for my $item (@$specs) {
        # Applicability gate: let each spec opt out of contexts it was
        # not designed for (e.g. test-job-only loggers on a service
        # collector). Blessed instances answer for themselves; everything
        # else is asked via its class.
        my $logger_class = blessed($item) ? $item : $self->_spec_class($item);
        next unless $logger_class->applicable($self);

        # service_name and job_id are mutually exclusive from the logger's
        # point of view (the role's output_file_basename croaks on both).
        # Service collectors identify by service_name; test collectors
        # identify by job_id. Collector::init defaults a random job_id
        # for every collector, so we must explicitly suppress it for
        # service collectors rather than pass both.
        my %identity = (
            logdir  => $self->{+LOGDIR},
            run_id  => $self->{+RUN_ID},
            job_try => $self->{+JOB_TRY},
            is_run  => $self->{+IS_RUN},
        );
        if (defined $self->{+SERVICE_NAME}) {
            $identity{service_name} = $self->{+SERVICE_NAME};
        }
        else {
            $identity{job_id} = $self->{+JOB_ID};
        }

        my $inst;
        if (blessed($item)) {
            # Pre-constructed instance: stamp info onto it via setters
            # since we cannot re-run its constructor.
            $item->set_process_info(%identity);
            $item->set_ipcm_info($self->{+IPCM_INFO});
            $item->set_auditor($self->auditor) if $self->auditor;
            $item->set_loggers_lookup($self->{+LOGGERS_LOOKUP});
            $inst = $item;
        }
        elsif (ref($item) eq 'ARRAY') {
            my ($class, @args) = @$item;
            $inst = $class->new(
                %identity,
                ipcm_info      => $self->{+IPCM_INFO},
                loggers_lookup => $self->{+LOGGERS_LOOKUP},
                (defined $self->auditor ? (auditor => $self->auditor) : ()),
                @args,
            );
        }
        else {
            $inst = $item->new(
                %identity,
                ipcm_info      => $self->{+IPCM_INFO},
                loggers_lookup => $self->{+LOGGERS_LOOKUP},
                (defined $self->auditor ? (auditor => $self->auditor) : ()),
            );
        }

        # Every logger has its identity attributes now, so it can
        # resolve its output path and create any directory trees its
        # output files will need before startup opens them.
        $inst->prepare_output_locations;

        $self->_add_logger($inst);
    }
}

# Append a logger instance to both the ordered LOGGERS array and the
# class-keyed LOGGERS_LOOKUP hash. Kept as a helper so anything that grows
# the logger set later stays in sync on both structures.
sub _add_logger {
    my $self = shift;
    my ($logger) = @_;

    push @{$self->{+LOGGERS}}                            => $logger;
    push @{$self->{+LOGGERS_LOOKUP}{ref $logger} //= []} => $logger;

    return $logger;
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

    # On Windows there is no fork, so we must serialize collector args and
    # spawn a fresh perl process via system(1, @cmd). Open file handles
    # cannot cross that boundary, so handle-based collection (stdout/stderr
    # attributes, or any non-launch path) is not supported.
    croak "Handle-based collection is not supported on Windows; use 'launch' instead"
        unless defined $self->{+LAUNCH};

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
    if (defined $self->_auditor_spec) {
        croak "Blessed auditor instances cannot be passed to a Windows collector; use class name or [class, \@args] form"
            if blessed($self->_auditor_spec);
        $params{auditor} = $self->_auditor_spec;
    }

    # Observers: same Windows-serialization constraint as loggers.
    for my $item (@{$self->{+_OBSERVERS_SPEC} // []}) {
        croak "Blessed observer instances cannot be passed to a Windows collector; use class name or [class, \@args] form"
            if blessed($item);
    }
    $params{observers} = $self->{+_OBSERVERS_SPEC} if $self->{+_OBSERVERS_SPEC};

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
    my $ok  = eval { $pid = $self->_win32_spawn(@cmd); 1 };
    my $err = $@;

    if (!$ok) {
        unlink($json_file);
        croak "Failed to spawn collector process (eval died): $err";
    }
    if (!defined $pid || $pid <= 0) {
        unlink($json_file);
        croak "Failed to spawn collector process (spawn returned ${\($pid // 'undef')}): $!";
    }

    return $pid;
}

# Class method invoked by the spawned collector process on Windows.
# Reads constructor args from a JSON file, builds a new Collector
# (skipping the spawn step), and runs the collection loop directly.
sub collect_from_file {
    my ($class, $file) = @_;

    # Guarantee the tempfile is removed even if this process dies before
    # decode_json_file runs (e.g. a module fails to load).  decode_json_file
    # with unlink => 1 still handles the normal path; if it fires first the
    # file is already gone and this becomes a no-op.
    my $file_guard = Scope::Guard->new(sub { unlink $file if -f $file });

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

    my ($child_pid, $out_r, $err_r, $started_child) = $self->_setup_child_handles();
    $self->_set_procname($child_pid);

    # Signal handlers. Installed with `local` so they restore automatically
    # when _run_collector returns (including via die), which is why they must
    # live in this top-level method rather than a helper.
    #
    # Ignore-class signals: tests and test-spawned child processes may send
    # these for their own coordination.  The collector must not die from them.
    # SIGPIPE in particular: write calls already check errno; we don't want a
    # broken-pipe to kill the collector.
    local $SIG{USR1} = 'IGNORE';
    local $SIG{USR2} = 'IGNORE';
    local $SIG{HUP}  = 'IGNORE';
    local $SIG{PIPE} = 'IGNORE';

    # Graceful-shutdown signals: TERM the watched child and let the existing
    # wait + exit-mirroring path handle cleanup.  We set $got_signal so the
    # main loop can notice and break out after draining remaining output.
    my $got_signal;
    local $SIG{TERM} = sub { $got_signal = 'TERM' };
    local $SIG{INT}  = sub { $got_signal = 'INT' };
    local $SIG{QUIT} = sub { $got_signal = 'QUIT' };

    my $parser = $self->_init_event_sinks();

    # Route collector-process warnings through the logger chain as WARNING
    # info events (see _make_warn_handler). Must stay in this scope for the
    # same `local` reason as the signal handlers above.
    local $SIG{__WARN__} = $self->_make_warn_handler;

    my ($buffer, $child_exit) = $self->_run_collection_loop(
        child_pid     => $child_pid,
        out_r         => $out_r,
        err_r         => $err_r,
        started_child => $started_child,
        parser        => $parser,
        got_signal    => \$got_signal,
    );

    $self->_finalize_collection($buffer, $parser, $child_exit);

    return 1;
}

sub _setup_child_handles {
    my $self = shift;

    my $started_child = defined($self->{+LAUNCH}) || $self->{+_OWNS_CHILD};

    if (defined $self->{+LAUNCH}) {
        my ($child_pid, $out_r, $err_r) = $self->_launch_child();
        $self->{+CHILD_PID} = $child_pid;
        return ($child_pid, $out_r, $err_r, $started_child);
    }

    my $child_pid = $self->{+CHILD_PID};

    # Wrap handles for the collection loop.
    # Pipe handles: wrap in Atomic::Pipe with mixed_data_mode.
    # Regular file handles: use a plain line-reader shim.
    # Fifo/pipe handles passed as file paths: also wrapped in Atomic::Pipe.
    my $out_r = defined($self->{+OUT_FH}) ? $self->_wrap_handle($self->{+OUT_FH}) : undef;
    my $err_r = defined($self->{+ERR_FH}) ? $self->_wrap_handle($self->{+ERR_FH}) : undef;

    return ($child_pid, $out_r, $err_r, $started_child);
}

# Build logger and auditor instances in the collector child process (so the
# parent never opens their file handles / sockets / etc.), start the loggers,
# cache the event-logging subset, and instantiate the parser. Returns the
# parser (which may be undef when no loggers and no auditor are configured).
sub _init_event_sinks {
    my $self = shift;

    # Auditor before loggers so loggers that want it can receive it as a
    # constructor argument (for new() specs) or via set_auditor() (for
    # pre-blessed instances, handled in _instantiate_loggers).
    $self->_instantiate_auditor();
    $self->_instantiate_observers();
    $self->_instantiate_loggers();

    # Lifecycle startup ordering matters: the auditor must be fully
    # started before observe_event ever sees an auditor-emitted event,
    # and every observer must be fully started before an auditor-
    # startup event reaches its observe_event. So we collect both
    # sources first (auditor events, then each observer's startup
    # events), *then* pipe the auditor events through the observer
    # chain, then concatenate the observers' own startup events, then
    # bring loggers up and replay the accumulated list.
    my @auditor_startup;
    if (my $auditor = $self->auditor) {
        @auditor_startup = grep { $_ } $auditor->startup($self);
    }

    my @observer_startup;
    for my $obs (@{$self->{+OBSERVERS} // []}) {
        push @observer_startup => grep { $_ } $obs->startup($self);
    }

    my @startup_events = $self->_pipe_through_observers(@auditor_startup);
    push @startup_events => @observer_startup;

    $_->startup($self) for @{$self->{+LOGGERS}};
    $self->{+_EVENT_LOGGERS} = [grep { $_->log_events } @{$self->{+LOGGERS}}];

    if (@startup_events && $self->{+_EVENT_LOGGERS} && @{$self->{+_EVENT_LOGGERS}}) {
        for my $e (@startup_events) {
            $_->log_event($e) for @{$self->{+_EVENT_LOGGERS}};
        }
    }

    # Once every logger has started (and knows its final locators, e.g. an
    # opened output file), report their metadata to the harness so it can
    # emit a job_loggers event. The message goes straight to the harness
    # (ipc_harness), not up through an intermediate parent service; only
    # the harness consumes it.
    $self->_send_logger_metadata;

    # When there is no parser the collector still drains the handles but
    # discards the lines without constructing events.
    my $parser = $self->{+PARSER};
    if (defined($parser) && !ref $parser) {
        $parser = $parser->new(ipcm_info => $self->{+IPCM_INFO});
    }
    elsif (defined $parser && ref $parser) {
        $parser->set_ipcm_info($self->{+IPCM_INFO});
    }

    return $parser;
}

# Lazy IPC handle per target bus name. One handle entry per unique
# target; each registers the collector on the IPC bus under its
# job_id so the receiving service can identify the sender. The
# collector sends only UPWARD (to its parent service or to the
# harness); it never holds a handle into the IPC identity of the
# process it is monitoring.
sub _ipc_client {
    my $self = shift;
    return $self->{_ipc_client} if $self->{_ipc_client};

    require IPC::Manager;
    # listen=0 (from ipc_default_connect_args): the collector only
    # ever sends UPWARD and never receives inbound traffic, so on
    # ConnectionUnix it skips the listen socket entirely. Drivers
    # that ignore the flag (MessageFiles, AtomicPipe, etc.) treat
    # the kwarg as a no-op.
    my $c = IPC::Manager->connect($self->bus_id, $self->{+IPCM_INFO}, ipc_default_connect_args());

    # The collector runs an event loop. Sends never block: queued
    # messages are flushed by the loop's per-iteration drain (see
    # _run_collection_loop). Clients without Role::Outbox inherit
    # the no-op set_send_blocking from IPC::Manager::Client base.
    $c->set_send_blocking(0);

    return $self->{_ipc_client} = $c;
}

# Wait briefly for $target to register on the bus so the first
# message we send to it actually lands. Matters mainly in the
# service-interpose flow where the collector and its parent
# service race through startup. Gated per-target so we only pay
# the wait once per peer.
#
# Returns truthy if the peer is registered (or was once -- a peer
# that came up and then disappeared still counts as "we saw it"),
# falsy if the wait timed out without the peer ever registering.
# Caller can use the return value to decide whether to attempt the
# send at all.
sub _wait_for_ipc_target {
    my ($self, $target) = @_;
    return $self->{_ipc_target_seen}->{$target}
        if $self->{_ipc_target_ready}->{$target}++;

    my $client = $self->_ipc_client;
    my $active;
    my $ok = eval { $active = $client->peer_active($target, 5); 1 };
    unless ($ok) {
        warn "Error waiting for ipc target '$target' to become ready (from '" . $self->bus_id . "'): $@";
        return $self->{_ipc_target_seen}->{$target} = 0;
    }
    return $self->{_ipc_target_seen}->{$target} = $active ? 1 : 0;
}

# Collector's own identity on the IPC bus. Per IPC_AND_LOGGERS §5.4
# this must be self-describing:
#
#   collector:<service_name>           -- non-run-scoped collectors
#                                         (harness's own, global resources,
#                                         global-scope preload stages).
#   collector:<service_name>:<run_id>  -- run-scoped collectors (run
#                                         service's own, run-scoped
#                                         resources, run-scoped preload
#                                         stages, test-job collectors
#                                         launched under a run).
#
# For service-interpose collectors, <service_name> is the interposed
# service's bus name (what it registered as). For test-job collectors
# there is no interposed service -- the test process is not a service --
# so we use the job_id as the disambiguator.
sub _build_collector_bus_id {
    my $self = shift;

    # Base-class fallback: pick whichever identifier we have. Subclasses
    # (Collector::Test, Collector::Service) tighten this down to the
    # one their role actually identifies by.
    my $collected_name = $self->{+IPC_PARENT} // $self->{+JOB_ID};

    croak "Could not determine the name of what we are collecting: set bus_id explicitly, or ensure at least one of ipc_parent / job_id is provided"
        unless $collected_name;

    return $self->_compose_bus_id($collected_name);
}

# Share the run-id suffix logic between the base's fallback and the
# subclass builders.
sub _compose_bus_id {
    my ($self, $collected_name) = @_;
    my $id = "collector:$collected_name";
    $id .= ":$self->{+IPC_RUN}"
        if defined $self->{+IPC_RUN}
        && (length($self->{+IPC_RUN}) + length($id) + 1) < 512;
    return $id;
}

# Public helper for observers: send to any known target using the
# collector's cached IPC handle pool and warn-on-failure semantics.
# Thin wrapper around _send_to so the underscore name stays
# internal. Observers that want to address ipc_run / ipc_harness /
# some other bus name go through here.
sub send_ipc {
    my ($self, $target, $content) = @_;
    return $self->_send_to($target, $content);
}

# Fire-and-forget send to a specific target service. Every send a
# collector performs goes UP the tree -- to ipc_parent, ipc_run, or
# ipc_harness -- and a collector never outlives its targets: a
# correctly-shut-down system tears the collector down before the
# services it talks to. A pipe / EPIPE error here therefore means
# a parent went away before its collector was torn down, which is
# a real bug (shutdown ordering, crashed peer, etc.) and wants to
# surface, not get silenced. All send failures warn. Returns
# nothing either way since the collector's lifecycle must never
# depend on delivery.
sub _send_to {
    my ($self, $target, $content) = @_;
    return unless defined $target;

    my $client = $self->_ipc_client;

    # Send with one retry. The MessageFiles protocol's try_send_message
    # croaks "Client does not exist" if the target's peer directory
    # is missing at send time; that can race with peer registration
    # at startup or peer teardown at shutdown. Re-check peer_active
    # once before giving up so the legitimately-late but still-alive
    # case stops emitting spurious warnings.
    #
    # try_send_message is non-blocking: queues on EAGAIN. The
    # collection loop calls drain_pending each iteration to flush
    # the queue when the transport reports writability.
    for my $attempt (1, 2) {
        my $ready = $self->_wait_for_ipc_target($target);

        my $ok = eval { $client->try_send_message($target, $content); 1 };
        return if $ok;

        my $err = $@;

        # On retry, force another peer_active poll the next time
        # around by clearing the gating cache for this target.
        if ($attempt == 1 && $ready) {
            delete $self->{_ipc_target_ready}->{$target};
            delete $self->{_ipc_target_seen}->{$target};
            next;
        }

        my $from = $self->bus_id // '?';
        my $role;
        $role = 'ipc_parent'  if defined $self->{+IPC_PARENT}  && $target eq $self->{+IPC_PARENT};
        $role = 'ipc_run'     if defined $self->{+IPC_RUN}     && $target eq $self->{+IPC_RUN};
        $role = 'ipc_harness' if defined $self->{+IPC_HARNESS} && $target eq $self->{+IPC_HARNESS};
        my $to = defined $role ? "$target ($role)" : $target;
        warn "Collector IPC send failed (kind '" . ($content->{kind} // '?') . "') from '$from' to '$to': $err";
        return;
    }

    return;
}

# Gather metadata from each instantiated logger, keyed by class so
# multiple instances of the same class coexist, and fire a one-shot
# `collector_artifacts` message (see IPC_AND_LOGGERS §8).
#
# Routing per §8.3: direct to ipc_run if the collector has one,
# else ipc_harness. Never via ipc_parent -- the intermediate parent
# (a preload stage, a resource service) has no use for the payload.
sub _send_logger_metadata {
    my $self = shift;

    # Harness interpose has ipc_run undef and ipc_harness == its own
    # child service -- nowhere useful to route logger metadata.
    return if $self->is_harness_collector;

    # Drop loggers that have nothing retrievable to report: a class with no
    # defined metadata does not appear at all, and a class keeps only the
    # slots that actually produced metadata.  The event still fires when
    # nobody contributed anything, with loggers => {}, so downstream
    # consumers always see the message.
    my %loggers;
    for my $logger (@{$self->{+LOGGERS}}) {
        my $meta = $logger->metadata;
        next unless defined $meta;
        my $class = ref($logger);
        push @{$loggers{$class}} => $meta;
    }

    my $target = $self->{+IPC_RUN} // $self->{+IPC_HARNESS};

    $self->_send_to(
        $target, {
            kind    => 'collector_artifacts',
            run_id  => $self->{+RUN_ID},
            job_id  => $self->{+JOB_ID},
            job_try => $self->{+JOB_TRY},
            loggers => \%loggers,
        }
    );

    return;
}

# Returns a coderef suitable for `local $SIG{__WARN__}`.
# Child-process warnings already flow through the stdout/stderr pipe to this
# process's parser chain, so no handler is needed on the child side.
# Collector-process warnings become WARNING info events on the logger chain;
# the renderer is responsible for surfacing them to the user. We do NOT echo
# to STDERR -- under prove / captured stderr that just clutters output, and
# in a normal run the renderer already shows the event.
sub _make_warn_handler {
    my $self = shift;

    return sub {
        my ($msg) = @_;

        my $ok = eval {
            my $event = Test2::Harness2::Event->new(
                event_id   => gen_uuid(),
                stamp      => time,
                facet_data => {
                    info => [{tag => 'WARNING', details => $msg, debug => 1}],
                },
            );
            $self->_process_event($event);
            1;
        };
        # Print STDERR rather than warn to avoid re-entering this handler.
        # This is only reached when logger dispatch itself fails -- at that
        # point the warning has nowhere else to go.
        print STDERR "Failed to log warning event ($msg): $@\n" unless $ok;
    };
}

sub _run_collection_loop {
    my $self = shift;
    my %args = @_;

    my $child_pid      = $args{child_pid};
    my $out_r          = $args{out_r};
    my $err_r          = $args{err_r};
    my $started_child  = $args{started_child};
    my $parser         = $args{parser};
    my $got_signal_ref = $args{got_signal};

    my $child_exited = 0;
    my $child_exit   = undef;
    my $stdout_eof   = defined($out_r) ? 0 : 1;
    my $stderr_eof   = defined($err_r) ? 0 : 1;

    # Merged if same handle object or err not provided
    my $merge_outputs = defined($out_r) && defined($err_r) && "$out_r" eq "$err_r";
    $stderr_eof = 1 if $merge_outputs;

    # IO::Select paces the loop so it parks on idle pipes instead of
    # busy-spinning through non-blocking reads. can_read also returns
    # immediately once a pipe closes, so EOF latency is unaffected. The
    # per-iteration parent-pid / signal / waitpid bookkeeping still fires
    # every $cycle seconds even when no I/O happens.
    my $cycle  = 0.2;
    my $sel    = IO::Select->new;
    my $out_fh = $stdout_eof ? undef : $self->_select_fh($out_r);
    my $err_fh = $stderr_eof ? undef : $self->_select_fh($err_r);
    $sel->add($out_fh) if defined $out_fh;
    $sel->add($err_fh) if defined $err_fh;

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
        # Flush any queued outbound IPC sends. The client is in
        # send_blocking=0 mode (set by _ipc_client). The kernel may
        # have made room in the FIFO since the previous iteration.
        # have_pending_sends short-circuits on the first peer with a
        # backlog; pending_sends would walk every peer summing queue
        # depths, which is wasted work on the hot path.
        my $client = $self->{_ipc_client};
        $client->drain_pending if $client && $client->have_pending_sends;

        # Build a write-side select set when the outbox has a
        # backlog so the loop wakes the moment room appears, even
        # on platforms without large pipe buffers.
        my $write_sel;
        if ($client && $client->have_writable_handles) {
            require IO::Select;
            my @wh = $client->writable_handles;
            if (@wh) {
                $write_sel = IO::Select->new;
                $write_sel->add(@wh);
            }
        }

        if ($sel->count || $write_sel) {
            require IO::Select;
            IO::Select->select($sel->count ? $sel : undef, $write_sel, undef, $cycle);
        }

        # Post-select drain: writable wake-up means the queue can
        # advance now. Read-side wake-up may also have made room
        # transitively.
        $client->drain_pending if $client && $client->have_pending_sends;

        my $ok = eval {
            # Check for signal - kill child but keep draining handles
            if ($$got_signal_ref && !$draining) {
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
                        $sel->remove($out_fh) if defined $out_fh;
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
                        $sel->remove($err_fh) if defined $err_fh;
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

    return ($buffer, $child_exit);
}

sub _finalize_collection {
    my $self = shift;
    my ($buffer, $parser, $child_exit) = @_;

    # Flush anything still sitting in the ordering buffer (items that never
    # got a matching sync marker).
    $self->_flush_buffer($buffer, $parser) if $parser;

    # Write exit event if we have an exit code, and stash it so the spawning
    # method can mirror the child's exit when it terminates the collector.
    if (defined $child_exit) {
        $self->{+CHILD_EXIT} = $child_exit;

        my $end_times   = [times()];
        my $start_times = $self->{+_START_TIMES};
        my @cpu_times   = map { $end_times->[$_] - $start_times->[$_] } 0 .. 3;

        my $px = parse_exit($child_exit);
        $px->{times} = \@cpu_times;

        my $exit_event = Test2::Harness2::Event->new(
            event_id   => gen_uuid(),
            stamp      => time,
            facet_data => {
                harness_process_exit => $px,
            },
        );
        $self->_process_event($exit_event);
    }

    # Lifecycle shutdown: mirrors the startup ordering. Auditor
    # shuts down first so its emitted events can still flow through
    # observe_event; each observer then shuts down with its events
    # going straight to the loggers. Loggers must not shut down
    # until every produced shutdown event has been log_event()'d.
    my @auditor_shutdown;
    if (my $auditor = $self->auditor) {
        @auditor_shutdown = grep { $_ } $auditor->shutdown($self);
    }

    my @observer_shutdown;
    for my $obs (@{$self->{+OBSERVERS} // []}) {
        push @observer_shutdown => grep { $_ } $obs->shutdown($self);
    }

    my @shutdown_events = $self->_pipe_through_observers(@auditor_shutdown);
    push @shutdown_events => @observer_shutdown;

    if (@shutdown_events && $self->{+_EVENT_LOGGERS} && @{$self->{+_EVENT_LOGGERS}}) {
        for my $e (@shutdown_events) {
            $_->log_event($e) for @{$self->{+_EVENT_LOGGERS}};
        }
    }

    $_->shutdown($self) for @{$self->{+LOGGERS}};

    return;
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

    # zstd compression on both pipes: write_message / write_burst
    # frames compress transparently while plain print writes (the
    # child's STDOUT/STDERR text stream) pass through uncompressed.
    my ($out_r, $out_w) = Atomic::Pipe->pair(mixed_data_mode => 1, atomic_pipe_compression_args());
    my ($err_r, $err_w) = Atomic::Pipe->pair(mixed_data_mode => 1, atomic_pipe_compression_args());

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

sub _win32_spawn {
    my $self = shift;
    # system(1, @cmd) on Win32 is _spawnvp(P_NOWAIT, ...) which returns the
    # pseudo-process ID (a positive integer) on success, or -1 on failure.
    # This is NOT the exit code — it is the PID to pass to waitpid().
    # Isolated in its own method so tests can override it without patching
    # CORE::GLOBAL::system (which does not intercept already-compiled opcodes).
    return system 1, @_;
}

sub _check_new_pgroup_supported_on_win32 {
    my $self = shift;

    return unless $self->{+NEW_PGROUP};

    # Win32::Job (AssignProcessToJobObject + TerminateJobObject) provides
    # the Windows equivalent of a process group: spawning into a job object
    # lets us terminate the child and all its descendants atomically, which
    # is required for Invariant 1 (child-process isolation).
    my $has_win32_job = eval { require Win32::Job; 1 };
    unless ($has_win32_job) {
        croak "new_pgroup => 1 on Windows requires Win32::Job (not installed); " . "install Win32::Job to enable process-group isolation";
    }
}

sub _launch_child_win32 {
    my $self = shift;
    my ($out_r, $out_w, $err_r, $err_w, $orig_stdout, $orig_stderr) = @_;

    $self->_check_new_pgroup_supported_on_win32();

    my $cmd = $self->{+LAUNCH};

    # When new_pgroup is requested, use Win32::Job so the child and all its
    # descendants can be terminated atomically (the Windows equivalent of
    # kill(0 - $pgid)).  _check_new_pgroup_supported_on_win32() already
    # verified that Win32::Job is loadable, so require it unconditionally here.
    return $self->_launch_child_win32_job($cmd, $out_w, $err_w)
        if $self->{+NEW_PGROUP};

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
        $ok = eval { $pid = $self->_win32_spawn(@$cmd); 1 };
    }
    my $err = $@;

    # Restore STDOUT/STDERR immediately after spawn.
    open(STDOUT, '>&', $orig_stdout) or croak "Could not restore STDOUT: $!";
    open(STDERR, '>&', $orig_stderr) or croak "Could not restore STDERR: $!";

    croak "Failed to spawn '@$cmd' (eval died): $err"
        if !$ok;
    croak "Failed to spawn '@$cmd' (spawn returned ${\($pid // 'undef')}): $!"
        if !defined $pid || $pid <= 0;

    return $pid;
}

sub _launch_child_win32_job {
    my $self = shift;
    my ($cmd, $out_w, $err_w) = @_;

    # Win32::Job was already verified loadable by _check_new_pgroup_supported_on_win32.
    require Win32::Job;

    my $job = Win32::Job->new()
        or croak "Failed to create Win32::Job object: $^E";

    # Build a properly-quoted command line string for CreateProcess.
    # Win32::Job->spawn() takes ($exe, $cmdline, \%opts).  The first element
    # of @$cmd is the executable; the full quoted string is the command line
    # (CreateProcess convention: argv[0] is embedded in it).
    my $exe     = $cmd->[0];
    my $cmdline = join(' ', map { $self->_win32_quote_arg($_) } @$cmd);

    my %env = $self->_child_env_overrides;

    # Merge overrides into the current environment for the spawn call.
    # Win32::Job->spawn inherits the parent environment; we simulate
    # local-env by temporarily setting the vars before spawning.
    local @ENV{keys %env} = values %env;

    # Pass the pipe write ends as the child's stdout/stderr.
    # Win32::Job->spawn accepts filehandles for stdin/stdout/stderr and
    # marks them inheritable before calling CreateProcess.
    my $pid = $job->spawn(
        $exe, $cmdline, {
            stdout => $out_w->wh,
            stderr => $err_w->wh,
        }
    );

    croak "Win32::Job->spawn('$exe') failed: $^E"
        unless defined $pid && $pid > 0;

    # Store the job object on the instance.  The job's lifetime is tied to
    # $self: when the Collector is destroyed, Win32::Job goes out of scope,
    # the job handle is closed, and Windows terminates all processes still
    # assigned to it — matching the Unix kill(0 - $pgid) semantics.
    $self->{+_WIN32_JOB} = $job;

    return $pid;
}

# Quoted-string helper for Win32 CreateProcess command lines.
# Rules: if the argument contains spaces or double-quotes, wrap it in
# double-quotes and escape any embedded double-quotes with a backslash.
sub _win32_quote_arg {
    my $self = shift;
    my ($arg) = @_;
    return $arg unless $arg =~ /[ \t"]/;
    $arg =~ s/"/\\"/g;
    return qq{"$arg"};
}

sub DESTROY {
    my $self = shift;
    # Release the Win32::Job handle explicitly.  When the last reference is
    # dropped, Windows closes the job handle.  Processes already assigned to
    # the job are terminated only if the job was created with
    # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE — Win32::Job sets this flag by
    # default, so all descendants are reaped atomically.
    delete $self->{+_WIN32_JOB};
}

sub _wrap_handle {
    my $self = shift;
    my ($handle) = @_;

    # Already an Atomic::Pipe object
    return $handle if blessed($handle) && $handle->isa('Atomic::Pipe');

    # Pipe or fifo filehandle -- wrap in Atomic::Pipe with mixed_data_mode
    # plus the standard zstd-with-dict compression config so framed
    # messages from the writer side decode here. from_fh does not
    # take extra constructor params, so configure compression
    # post-construction via set_compression / set_compression_dictionary_file.
    if (-p $handle) {
        my $ap = Atomic::Pipe->from_fh('<&', $handle);
        $ap->set_mixed_data_mode();
        apply_atomic_pipe_compression($ap);
        return $ap;
    }

    # Regular file handle -- use plain line-reader shim, no Atomic::Pipe.
    return Test2::Harness2::Collector::FileLineReader->new($handle);
}

# Pulls a raw filehandle out of whatever _wrap_handle produced, for use with
# IO::Select. Returns undef for unknown handle shapes (callers must treat
# that as "cannot be select()ed" and fall back to the read path).
sub _select_fh {
    my $self = shift;
    my ($handle) = @_;
    return undef unless defined $handle;
    return $handle->rh   if blessed($handle) && $handle->isa('Atomic::Pipe');
    return $handle->{fh} if blessed($handle) && $handle->isa('Test2::Harness2::Collector::FileLineReader');
    return undef;
}

sub _read_handle {
    my $self = shift;
    my ($handle) = @_;

    # Atomic::Pipe handles -- return [type, data, $compressed_or_undef]
    # tuples so the caller can distinguish atomic message bursts
    # (JSON events) from plain lines. With keep_compressed enabled,
    # message and burst frames also carry the on-wire compressed
    # bytes via a "compressed => $raw" pair on the return list; we
    # promote that into the tuple so downstream consumers (event
    # parser, zstd logger) can reuse the frame without recompressing.
    if (blessed($handle) && $handle->isa('Atomic::Pipe')) {
        my @items;

        while (1) {
            my @res = $handle->get_line_burst_or_data();
            last unless defined $res[0];
            my ($type, $data, @rest) = @res;
            my %extra = @rest;
            push @items => [$type, $data, $extra{compressed}];
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

    my ($type, $data, $compressed) = @$item;
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

        # Stash $compressed alongside the decoded payload so the
        # parser can attach it to the resulting Event for the JSONL
        # zstd logger's reuse path. Sync markers on STDERR carry a
        # compressed form too but the collector never logs them, so
        # the bytes are kept for symmetry only.
        push @{$buffer->{$stream}} => [$stamp, message => $decoded, $compressed];

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
            my ($stamp, $kind, $val, $compressed) = @$entry;

            if ($kind eq 'message') {
                if ($stream eq 'stdout') {
                    # A real event arrived via a burst -- feed it through
                    # the parser so the harness facet still gets populated.
                    my $event = $parser->parse_io(
                        stream     => $stream,
                        event      => $val,
                        stamp      => $stamp,
                        compressed => $compressed,
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

# Thread a list of events through the configured observer chain.
# Each observer sees one event at a time and returns the list it
# wants handed downstream; the next observer then sees each of
# those. Same semantic as what _process_event applies per-event,
# exposed as a helper so startup / shutdown can reuse it on the
# lifecycle-event lists.
sub _pipe_through_observers {
    my ($self, @events) = @_;

    my $observers = $self->{+OBSERVERS} or return @events;
    return @events unless @$observers;

    for my $obs (@$observers) {
        my @out;
        for my $e (@events) {
            next unless $e;
            push @out => $obs->observe_event($e);
        }
        @events = @out;
    }

    return @events;
}

sub _process_event {
    my $self = shift;
    my ($event) = @_;

    return unless $event;

    my @events;
    if (my $auditor = $self->auditor) {
        @events = $auditor->audit_event($event);

        if (!$self->{+_FAILING_NOTIFIED} && $auditor->failing) {
            $_->failing(1) for @{$self->{+LOGGERS}};
            $self->{+_FAILING_NOTIFIED} = 1;
        }
    }
    else {
        @events = ($event);
    }

    # Observer chain: same contract as the auditor -- each observer
    # sees one event at a time and returns the list it wants handed
    # downstream (normally the incoming event plus any synth). The
    # pipeline threads observers in listed order: observer N sees
    # whatever observer N-1 returned.
    @events = $self->_pipe_through_observers(@events);

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

    # Drain any queued outbound IPC sends before exit. The collector
    # was running in send_blocking=0 mode (set by _ipc_client) so
    # events accumulated during the run are still in the client's
    # outbox; without this drain they would be dropped when this
    # process _exits. Loop until the queue clears or a 5s deadline
    # is hit (avoid wedging an exit on a peer that isn't reading).
    if (my $client = $self->{_ipc_client}) {
        # The Outbox API (have_pending_sends + drain_pending) is
        # provided as a no-op fallback by the IPC::Manager::Client
        # base class for backends that do not consume Role::Outbox,
        # so no can() gate is needed -- non-Outbox clients exit the
        # loop after the first iteration when have_pending_sends
        # returns 0.
        my $deadline = time + 5;
        while ($client->have_pending_sends && time < $deadline) {
            last unless $client->drain_pending;
            tinysleep(0.01) if $client->have_pending_sends;
        }
    }

    POSIX::_exit(255) unless $collector_ok;

    if (defined(my $child_exit = $self->{+CHILD_EXIT})) {
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
        tinysleep(0.1);
    }

    # Force kill
    kill('KILL', $pid);
    my $rv = waitpid($pid, 0);
    return $?;
}

# Fork, and let the child continue the caller's execution path while the
# parent becomes the collector for whatever the child does. Never returns in
# the parent.
#
# Optional parameters:
#
#   jump_to      -- name of a currently-active Long::Jump setjump. When set,
#                   the interpose child does a longjump() back to that point
#                   after the pipes are wired up, rather than returning
#                   normally. The caller's stack is unwound to the setjump,
#                   giving cleaner stack traces for the code that runs
#                   under the collector.
#
#   jump_payload -- an optional coderef passed through longjump() to the
#                   setjump. Typically the caller uses this to hand the
#                   "continue the work" closure back to the setjump site.
#                   Requires jump_to.
sub interpose {
    my ($class, %params) = @_;

    croak "interpose() is a class method"           if ref $class;
    croak "interpose() is not supported on Windows" if IS_WIN32;

    my $jump_to      = delete $params{jump_to};
    my $jump_payload = delete $params{jump_payload};

    croak "'jump_payload' must be a code reference"
        if defined($jump_payload) && ref($jump_payload) ne 'CODE';
    croak "'jump_payload' requires 'jump_to'"
        if defined($jump_payload) && !defined($jump_to);

    if (defined $jump_to) {
        require Long::Jump;
        croak "No active setjump named '$jump_to'"
            unless Long::Jump::havejump($jump_to);
    }

    ($params{out_r}, $params{out_w}) = Atomic::Pipe->pair(mixed_data_mode => 1, atomic_pipe_compression_args());
    ($params{err_r}, $params{err_w}) = Atomic::Pipe->pair(mixed_data_mode => 1, atomic_pipe_compression_args());

    open($params{orig_stdout}, '>&', \*STDOUT) or croak "Could not clone STDOUT: $!";
    open($params{orig_stderr}, '>&', \*STDERR) or croak "Could not clone STDERR: $!";

    my $pid = fork() // die "Failed to fork for interpose: $!";

    # Parent becomes the collector and exits when done -- does not return
    if ($pid) {
        $params{pid} = $pid;
        $class->_interpose_parent(\%params);
    }

    # Child: complete handle setup, then either return to the caller or
    # unwind the stack back to the named setjump with the caller's payload.
    $class->_interpose_child(\%params);

    if (defined $jump_to) {
        Long::Jump::longjump($jump_to, $jump_payload);
        # longjump does not return on success; if we're still here something
        # has gone seriously wrong.
        POSIX::_exit(255);
    }

    return;
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

    # Tell downstream readers (Stream2 formatter, Harness2 service
    # run_service, etc.) how many mixed-mode pipes the collector is
    # actually reading. interpose() always creates two (stdout + stderr,
    # separate), so the child advertises 2. This is the same contract
    # _child_env_overrides publishes to launch-path children, and it is
    # the reliable signal -- filenos alone cannot distinguish a merged
    # setup (both fds dup'd onto the same pipe) from separate pipes.
    $ENV{T2_HARNESS2_PIPE_COUNT} = 2;
}

1;
