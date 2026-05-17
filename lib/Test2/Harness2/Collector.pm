package Test2::Harness2::Collector;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use Config;
use Fcntl qw/:flock O_WRONLY O_APPEND O_CREAT/;
use File::Path qw/make_path/;
use POSIX qw/:sys_wait_h setpgid/;
use Time::HiRes qw/time/;
use Scalar::Util qw/blessed refaddr/;
use Scope::Guard ();
use IO::Handle;
use IO::Select;
use Atomic::Pipe;
use MIME::Base64 qw/decode_base64/;

use Test2::Harness2::Event;
use Test2::Harness2::Collector::Handle;
use Test2::Harness2::Collector::Util qw/make_warn_handler kill_child/;
use Test2::Harness2::LogLayout qw/collector_base_dir/;
use Test2::Harness2::Util qw/load_module parse_exit tinysleep write_file_atomic/;
use Test2::Harness2::Util::JSON qw/decode_json encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer compress_blob/;
use Test2::Harness2::Util::IPC qw/pid_is_running set_procname swap_io ipc_default_connect_args atomic_pipe_compression_args apply_atomic_pipe_compression/;

# Single Collector class. The Logger and Observer abstractions are
# gone; the collector writes its three .jsonl.zst files directly.
# Test-job collectors carry an Auditor::Test (which has absorbed
# TestObserver's IPC duties); run and service collectors are dumb
# pass-throughs.
#
# Construction takes:
#   type    'Job' | 'Run' | 'Service'   -- required
#   id      ord int (Job/Run) or service name (Service) -- required
#   run_id  ord int (defined for type=Run, type=Job, run-scoped services)
#   job_try integer (only meaningful for type=Job)
#   logdir  the workdir's logs/ directory -- required
#
# The base dir for this collector under $logdir is computed from the
# four identity slots above; the trio
# (spec.jsonl.zst, events.jsonl.zst, report.jsonl.zst) is appended
# directly to that base dir.
# `launch_callback` is the authoritative spawn hook for preloaded
# tests. When set (in lieu of `launch`), the collector's post-fork
# child invokes the callback in-process -- no exec -- so a
# Long::Jump out of the callback can unwind back to a setjump
# anchor in an outer preload service and hand off to goto::file.
# Tests routed this way retain the parent's preloaded %INC and end
# up parsed in main with a shallow stack as if perl had been
# started with the test file directly. Mutually exclusive with
# `launch`.
use Object::HashBase qw{
    <type
    <id
    <launch
    <launch_callback
    <post_fork_callback
    <new_pgroup
    <cwd
    <env_vars
    <out_fh
    <err_fh
    <child_pid
    <parser
    <auditor
    <parent_pids
    <kill_timeout
    <logdir
    <run_id
    <job_try
    <spec
    <ipcm_info
    <ipc_parent
    <ipc_run
    <ipc_harness
    <bus_id

    +_started
    <_owns_child

    +_auditor_spec
    +_failing_notified
    <child_exit

    +_base_dir
    +_spec_writer
    +_events_writer
    +_report_writer
    +_state
    +_pending_collector_report
    +_pending_exit_timing
    +_attachment_counter
    +_attachment_dir_made

    +_win32_job
    +_start_times
    +_child_fork_times
    +_child_fork_stamp
};

use constant IS_WIN32 => $^O eq 'MSWin32';

# Load Win32-only collector code (extra methods + DESTROY) into the
# Test2::Harness2::Collector class namespace. Done at compile time so
# the methods are available before any instance is constructed.
require Test2::Harness2::Collector::Win32 if IS_WIN32;

use constant VALID_TYPES => {map { $_ => 1 } qw/Job Run Service/};

sub init {
    my $self = shift;

    my $type = $self->_init_validate_identity;

    # Map spec constructor names to internal attribute names so callers can
    # use the natural names from the spec (stdout, stderr, pid, env) even
    # though HashBase cannot use those as constants due to Perl reserved words.
    $self->{+OUT_FH}    //= delete $self->{stdout} if exists $self->{stdout};
    $self->{+ERR_FH}    //= delete $self->{stderr} if exists $self->{stderr};
    $self->{+CHILD_PID} //= delete $self->{pid}    if exists $self->{pid};
    $self->{+ENV_VARS}  //= delete $self->{env}    if exists $self->{env};

    $self->{+_START_TIMES} = [times()];

    $self->{+KILL_TIMEOUT} //= 15;
    $self->{+ENV_VARS}     //= {};
    $self->{+NEW_PGROUP}   //= 0;
    $self->{+SPEC}         //= {};

    # Compose collector bus_id. Test-job collectors identify by id (the
    # job's ordinal); other collectors identify by id (service name or
    # run ordinal). The harness's own collector overrides bus_id
    # explicitly (it passes its own bus name in).
    $self->{+BUS_ID} //= $self->_build_collector_bus_id;

    $self->_init_validate_auditor($type);
    $self->_init_validate_launch_and_stdio;

    # Default parser. Always present so the write_phase has a parsed
    # event to serialize.
    $self->{+PARSER} //= 'Test2::Harness2::Collector::Parser::IOParser';

    # Load parser class if it's a class name
    load_module($self->{+PARSER})
        if defined($self->{+PARSER}) && !ref $self->{+PARSER};
}

# Validate required identity attributes (ipcm_info, ipc_harness,
# type, id, run_id-when-Job, logdir) and return the validated type
# string. Defaults +JOB_TRY when type is Job.
sub _init_validate_identity {
    my $self = shift;

    croak "'ipcm_info' is a required attribute"
        unless defined $self->{+IPCM_INFO};

    croak "'ipc_harness' is a required attribute"
        unless defined $self->{+IPC_HARNESS};

    my $type = $self->{+TYPE} // croak "'type' is a required attribute (Job/Run/Service)";
    croak "Invalid type '$type' (want Job/Run/Service)"
        unless VALID_TYPES->{$type};

    croak "'id' is a required attribute"
        unless defined $self->{+ID} && length $self->{+ID};

    if ($type eq 'Job') {
        croak "'run_id' is required for type=Job"
            unless defined $self->{+RUN_ID};
        $self->{+JOB_TRY} //= 1;
    }

    croak "'logdir' is a required attribute"
        unless defined $self->{+LOGDIR} && length $self->{+LOGDIR};

    return $type;
}

# Validate the +AUDITOR spec for Job collectors (auditors are
# meaningless for run/service collectors). Loads the auditor class
# when given by name, stashes the original spec in +_AUDITOR_SPEC,
# and clears +AUDITOR so the child re-instantiates.
sub _init_validate_auditor {
    my $self = shift;
    my ($type) = @_;

    return unless $type eq 'Job' && defined $self->{+AUDITOR};

    my $auditor = $self->{+AUDITOR};
    if (!blessed($auditor)) {
        my $class = ref($auditor) eq 'ARRAY' ? $auditor->[0] : $auditor;
        croak "Auditor spec must be a class name, [class, args], or instance"
            unless defined $class && !ref($class);
        load_module($class);
        croak "Auditor '$class' does not implement Test2::Harness2::Role::Auditor"
            unless Role::Tiny::does_role($class, 'Test2::Harness2::Role::Auditor');
    }
    $self->{+_AUDITOR_SPEC} = $self->{+AUDITOR};
    $self->{+AUDITOR}       = undef;               # re-instantiated in the child

    return;
}

# Validate the mutually-exclusive launch / launch_callback / stdio
# spec triple, normalize +LAUNCH to arrayref form, and open any
# stdio paths supplied as strings.
sub _init_validate_launch_and_stdio {
    my $self = shift;

    my $has_launch   = defined $self->{+LAUNCH};
    my $has_callback = defined $self->{+LAUNCH_CALLBACK};
    my $has_stdio    = defined($self->{+OUT_FH}) || defined($self->{+ERR_FH});

    croak "'launch' and 'launch_callback' are mutually exclusive"
        if $has_launch && $has_callback;

    my $has_any_launch = $has_launch || $has_callback;

    croak "Must specify launch / launch_callback or stdout/stderr, not both"
        if $has_any_launch && $has_stdio;

    croak "Must specify launch / launch_callback or stdout/stderr"
        unless $has_any_launch || $has_stdio;

    croak "'launch_callback' must be a code ref"
        if $has_callback && ref($self->{+LAUNCH_CALLBACK}) ne 'CODE';

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

    return;
}

# Compute and cache the absolute base dir for this collector.
sub base_dir {
    my $self = shift;
    return $self->{+_BASE_DIR} //= $self->{+LOGDIR} . '/' . collector_base_dir(
        type    => $self->{+TYPE},
        id      => $self->{+ID},
        run_id  => $self->{+RUN_ID},
        job_try => $self->{+JOB_TRY},
    );
}

# Collector identity for the IPC bus. Run and service collectors use
# their id as the disambiguator; job collectors use their (run, id,
# try) triple. The harness's own collector overrides bus_id explicitly.
sub _build_collector_bus_id {
    my $self = shift;

    my $type = $self->{+TYPE};
    my $id   = $self->{+ID};

    my $name;
    if ($type eq 'Job') {
        $name = "job:$id";
    }
    elsif ($type eq 'Run') {
        $name = "run:$id";
    }
    else {
        $name = "service:$id";
    }

    my $bus = "collector:$name";
    if (defined $self->{+RUN_ID} && (length($self->{+RUN_ID}) + length($bus) + 1) < 512) {
        $bus .= ":" . $self->{+RUN_ID};
    }
    return $bus;
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
    # heavyweight Collector instance is not kept alive in the parent.
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
    #
    # Stash the guard on $self (not just a my-var) so a deeper fork --
    # specifically, the test grandchild a launch_callback spawns -- can
    # dismiss it before calling exit(). Without that, the test child's
    # `exit(0)` unwinds inherited scopes, fires this guard's DESTROY in
    # the grandchild process, and POSIX::_exit(255)'s before Test2's END
    # block + Stream2 formatter finalize get to emit the plan.
    $self->{_collector_guard} = Scope::Guard->new(sub { POSIX::_exit(255) });

    my $ok  = eval { $self->_run_collector(); 1 };
    my $err = $@;

    $self->_emit_collector_error("Collector process died: $err") unless $ok;

    $self->{_collector_guard}->dismiss;
    $self->_exit_mirroring_child($ok);
}

sub _run_collector {
    my $self = shift;

    # Reset CPU-time baseline now that we're in the process that will
    # actually run the collection loop.
    $self->{+_START_TIMES} = [times()];

    # Role::Preload's post_fork hook lands here: this is the first
    # child of the preload service's spawn, before the collector
    # forks again for the test grandchild. The callback runs in the
    # collector process and must be cheap (the collector starts its
    # auditing loop immediately after).
    if (my $cb = $self->{+POST_FORK_CALLBACK}) {
        eval { $cb->($self); 1 } or warn "post_fork_callback failed: $@";
    }

    my ($child_pid, $out_r, $err_r, $started_child) = $self->_setup_child_handles();
    $self->_set_procname($child_pid);

    # Open the writer trio + spec row before any event flows so a
    # crash mid-collection still leaves spec.jsonl.zst usable.
    $self->_open_writers();
    my $spec_hash = $self->_write_spec_row();

    # The harness's own collector (no parent service) drops a LIVE
    # sentinel at <logdir>/LIVE so consumers can detect a still-being-
    # written log. Removed in _finalize_collection on clean exit. A
    # crashed harness leaves a stale LIVE which consumers can use to
    # spot abnormal termination.
    $self->_create_live_sentinel;

    # Tell the parent service we're up. Emission is skipped for
    # collectors with no parent (both ipc_parent and ipc_run undef --
    # today only the harness collector matches).
    $self->_emit_collector_start($spec_hash);

    # Signal handlers. Installed with `local` so they restore automatically
    # when _run_collector returns (including via die).
    local $SIG{USR1} = 'IGNORE';
    local $SIG{USR2} = 'IGNORE';
    local $SIG{HUP}  = 'IGNORE';
    local $SIG{PIPE} = 'IGNORE';

    my $got_signal;
    local $SIG{TERM} = sub { $got_signal = 'TERM' };
    local $SIG{INT}  = sub { $got_signal = 'INT' };
    local $SIG{QUIT} = sub { $got_signal = 'QUIT' };

    my $parser = $self->_init_pipeline();

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

    my $has_launch    = defined($self->{+LAUNCH}) || defined($self->{+LAUNCH_CALLBACK});
    my $started_child = $has_launch               || $self->{+_OWNS_CHILD};

    if ($has_launch) {
        my ($child_pid, $out_r, $err_r) = $self->_launch_child();
        $self->{+CHILD_PID} = $child_pid;
        return ($child_pid, $out_r, $err_r, $started_child);
    }

    my $child_pid = $self->{+CHILD_PID};

    my $out_r = defined($self->{+OUT_FH}) ? $self->_wrap_handle($self->{+OUT_FH}) : undef;
    my $err_r = defined($self->{+ERR_FH}) ? $self->_wrap_handle($self->{+ERR_FH}) : undef;

    return ($child_pid, $out_r, $err_r, $started_child);
}

# Pipeline init: build auditor (Job-only), open parser instance.
sub _init_pipeline {
    my $self = shift;

    if ($self->{+TYPE} eq 'Job' && $self->{+_AUDITOR_SPEC}) {
        my $spec = $self->{+_AUDITOR_SPEC};
        my $inst;
        if (blessed($spec)) {
            $inst = $spec;
            $inst->set_process_info(
                run_id  => $self->{+RUN_ID},
                job_id  => $self->{+ID},
                job_try => $self->{+JOB_TRY},
            );
            $inst->set_ipcm_info($self->{+IPCM_INFO});
        }
        elsif (ref($spec) eq 'ARRAY') {
            my ($class, @args) = @$spec;
            $inst = $class->new(
                run_id    => $self->{+RUN_ID},
                job_id    => $self->{+ID},
                job_try   => $self->{+JOB_TRY},
                ipcm_info => $self->{+IPCM_INFO},
                @args,
            );
        }
        else {
            $inst = $spec->new(
                run_id    => $self->{+RUN_ID},
                job_id    => $self->{+ID},
                job_try   => $self->{+JOB_TRY},
                ipcm_info => $self->{+IPCM_INFO},
            );
        }
        $self->{+AUDITOR} = $inst;

        # Auditor startup may emit events (e.g. test_job_started IPC).
        # Any returned event is sent through write_phase like normal.
        my @startup = grep { $_ } $inst->startup($self);
        for my $e (@startup) {
            $self->_write_event($e);
        }
    }

    my $parser = $self->{+PARSER};
    if (defined($parser) && !ref $parser) {
        $parser = $parser->new(ipcm_info => $self->{+IPCM_INFO});
    }
    elsif (defined $parser && ref $parser) {
        $parser->set_ipcm_info($self->{+IPCM_INFO});
    }

    return $parser;
}

# Open the spec/events/report writers under the collector's base dir.
# The dir is created on demand. If the files already exist we append
# (zstd is concatenable; subsequent frames just append to the file).
sub _open_writers {
    my $self = shift;

    my $base = $self->base_dir;
    make_path($base);

    my $events_path = "$base/events.jsonl.zst";
    my $spec_path   = "$base/spec.jsonl.zst";
    my $report_path = "$base/report.jsonl.zst";

    $self->{+_EVENTS_WRITER} = open_zstd_writer($events_path);
    $self->{+_SPEC_WRITER}   = open_zstd_writer($spec_path);
    $self->{+_REPORT_WRITER} = open_zstd_writer($report_path);
}

# Append the spec row. Always one row per startup. The row is whatever
# `spec` hash the caller handed us, plus the collector pid. Returns
# the assembled hash so the caller can reuse it for the matching
# collector_start IPC emission.
sub _write_spec_row {
    my $self = shift;
    my $w    = $self->{+_SPEC_WRITER} or return;

    my %spec = (
        %{$self->{+SPEC} // {}},
        collector_pid => $$,
        type          => $self->{+TYPE},
        id            => $self->{+ID},
        (defined $self->{+RUN_ID}  ? (run_id  => $self->{+RUN_ID})  : ()),
        (defined $self->{+JOB_TRY} ? (job_try => $self->{+JOB_TRY}) : ()),
        started_at => time,
    );

    require Test2::Harness2::Util::JSON;
    $w->say(Test2::Harness2::Util::JSON::encode_json(\%spec));

    return \%spec;
}

# Cached IPC client for upward sends.
sub _ipc_client {
    my $self = shift;
    return $self->{_ipc_client} if $self->{_ipc_client};

    require IPC::Manager;
    my $c = IPC::Manager->connect($self->bus_id, $self->{+IPCM_INFO}, ipc_default_connect_args());
    $c->set_send_blocking(0);

    return $self->{_ipc_client} = $c;
}

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

# Public helper: send to any known target. Used by Auditor::Test (it
# took over TestObserver's IPC duties).
sub send_ipc {
    my ($self, $target, $content) = @_;
    return $self->_send_to($target, $content);
}

# Pick the parent IPC target for the lifecycle pair (collector_start /
# collector_end). Routing:
#
#   * Job collectors    -- ipc_run is the immediate parent (run service)
#                          and is also where the lifecycle IPC goes.
#   * Run collectors    -- ipc_parent (= harness) gets the lifecycle IPC.
#                          (Their ipc_run slot points at the run service
#                          itself, but a service does not reflect its own
#                          lifecycle pair into its own event stream --
#                          the harness does.)
#   * Service collectors -- run-scoped or global -- send to ipc_parent
#                           (run service or harness respectively).
#   * Harness collector  -- both ipc_parent and ipc_run undef, returns
#                           undef so the caller skips emission.
sub _lifecycle_ipc_target {
    my $self = shift;
    my $type = $self->{+TYPE} // '';
    return $self->{+IPC_RUN}    if $type eq 'Job' && defined $self->{+IPC_RUN};
    return $self->{+IPC_PARENT} if defined $self->{+IPC_PARENT};
    return $self->{+IPC_RUN}    if defined $self->{+IPC_RUN};
    return undef;
}

# Build the common identity payload shared by collector_start and
# collector_end. All keys are present (set to undef where N/A) per
# the spec rule "don't be fancy with key omission".
sub _lifecycle_base_payload {
    my $self = shift;

    my $type = $self->{+TYPE};

    return (
        type          => $type,
        id            => $self->{+ID},
        run_id        => $self->{+RUN_ID},
        job_id        => ($type eq 'Job'     ? $self->{+ID}      : undef),
        job_try       => ($type eq 'Job'     ? $self->{+JOB_TRY} : undef),
        service_name  => ($type eq 'Service' ? $self->{+ID}      : undef),
        collector_pid => $$,
        collected_pid => $self->{+CHILD_PID},
    );
}

# True when this collector is the top-of-tree harness collector: no
# parent service to notify, no enclosing run. Today exactly one
# collector matches (the one App::Yath2::Command::test interposes).
# Used to gate the LIVE sentinel lifecycle.
sub _is_top_level_harness {
    my $self = shift;
    return 0 if defined $self->{+IPC_PARENT};
    return 0 if defined $self->{+IPC_RUN};
    return 1;
}

# Drop the LIVE sentinel at <logdir>/LIVE. The file content is a
# literal "1\n" so a stale LIVE is trivially distinguishable from an
# empty placeholder. Only the top-level harness collector creates it.
sub _create_live_sentinel {
    my $self = shift;
    return unless $self->_is_top_level_harness;
    my $path = $self->{+LOGDIR} . '/LIVE';
    return if -e $path;
    write_file_atomic($path, "1\n");
    return;
}

# Remove the LIVE sentinel if present. Called by _finalize_collection
# on clean exit. A crashing harness skips this and leaves the file in
# place -- consumers (e.g. the test command's renderer child) use that
# as a hint that something went wrong.
sub _remove_live_sentinel {
    my $self = shift;
    return unless $self->_is_top_level_harness;
    my $path = $self->{+LOGDIR} . '/LIVE';
    unlink $path if -e $path;
    return;
}

# Shared-writer LIVE append. Every collector that observes a producer
# open/close calls this; flock(LOCK_EX) serializes concurrent writers.
# No IPC routing -- the file is the bus. flock is required because bare
# O_APPEND atomicity is insufficient under PerlIO buffering and across
# network filesystems (NFS/SMB/Windows).
# The appended line is a tiny wake-up signal; renderers re-scan the Log
# on wake and do not parse LIVE for state.
sub _live_append {
    my ($self, $payload) = @_;
    my $path = $self->{+LOGDIR} . '/LIVE';
    my $line = encode_json($payload) . "\n";
    sysopen(my $fh, $path, O_WRONLY | O_APPEND | O_CREAT, 0644)
        or die "open $path: $!";
    flock($fh, LOCK_EX)  or die "flock $path: $!";
    syswrite($fh, $line) or die "write $path: $!";
    flock($fh, LOCK_UN);
    close($fh);
    return;
}

# Send collector_start IPC to the lifecycle target if one exists.
# $spec_hash is the same hash just written to spec.jsonl.zst (for
# downstream introspection).
sub _emit_collector_start {
    my ($self, $spec_hash) = @_;

    my $target = $self->_lifecycle_ipc_target;
    return unless defined $target;

    $self->_send_to(
        $target, {
            kind => 'collector_start',
            $self->_lifecycle_base_payload,
            started_at => time,
            spec       => $spec_hash // {},
        }
    );

    return;
}

# Send collector_end IPC to the lifecycle target if one exists.
# Payload always carries exit/exit_decoded/ended_at plus a state hash.
# For Jobs the state hash is the auditor's final state; for Run/Service
# it carries just the exit/timing info (the service-emitted
# collector_report facet rides through the event stream separately and
# is merged into report.jsonl.zst by the collector before this
# emission -- see _write_report_row).
sub _emit_collector_end {
    my ($self, $child_exit) = @_;

    my $target = $self->_lifecycle_ipc_target;
    return unless defined $target;

    my $ended_at     = time;
    my $exit_decoded = defined($child_exit) ? parse_exit($child_exit) : undef;

    my %state = (
        exit          => $child_exit,
        exit_decoded  => $exit_decoded,
        ended_at      => $ended_at,
        collector_pid => $$,
        collected_pid => $self->{+CHILD_PID},
    );

    if ($self->{+TYPE} eq 'Job' && (my $auditor = $self->{+AUDITOR})) {
        if (my $final = $self->_auditor_final_state($auditor)) {
            %state = (%$final, %state);
        }
    }

    $self->_send_to(
        $target, {
            kind => 'collector_end',
            $self->_lifecycle_base_payload,
            exit         => $child_exit,
            exit_decoded => $exit_decoded,
            ended_at     => $ended_at,
            state        => \%state,
        }
    );

    return;
}

sub _send_to {
    my ($self, $target, $content) = @_;
    return unless defined $target;

    my $client = $self->_ipc_client;

    for my $attempt (1, 2) {
        my $ready = $self->_wait_for_ipc_target($target);

        # Suppress IPC::Manager's connection-level "send to X failed:
        # Broken pipe" carps -- they happen routinely when a parent
        # service has already shut down by the time we try to send our
        # collector_end. We surface the failure ourselves below if it
        # was the second attempt.
        my $ok = eval {
            local $SIG{__WARN__} = sub { };
            $client->try_send_message($target, $content);
            1;
        };
        return if $ok;

        my $err = $@;

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
        # Broken-pipe / peer-gone is normal at shutdown when our
        # parent service has already exited. Anything else still
        # rates a warning so the caller notices.
        my $is_peer_gone = $err =~ /broken pipe|peer .* went away|not a valid message recipient/i;
        warn "Collector IPC send failed (kind '" . ($content->{kind} // '?') . "') from '$from' to '$to': $err"
            unless $is_peer_gone;
        return;
    }

    return;
}

sub _make_warn_handler {
    my $self = shift;
    return make_warn_handler(sub { $self->_process_event($_[0]) });
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

    my $state  = $self->_init_collection_state($out_r, $err_r);
    my $term   = $self->_init_termination_state;
    my $buffer = {seen => {}, saw_event => 0, stdout => [], stderr => []};

    while (1) {
        my $client = $self->{_ipc_client};
        $client->drain_pending if $client && $client->have_pending_sends;

        my $write_sel = $self->_build_write_select($client);

        my $tick = $self->_compute_loop_tick($state->{cycle}, $term);

        if ($state->{sel}->count || $write_sel) {
            require IO::Select;
            IO::Select->select($state->{sel}->count ? $state->{sel} : undef, $write_sel, undef, $tick);
        }

        $client->drain_pending if $client && $client->have_pending_sends;

        my $ok = eval {
            $self->_check_termination_signals($term, $got_signal_ref, $child_pid, $started_child, $state->{child_exited});

            $self->_drain_input_handles($state, $out_r, $err_r, $buffer, $parser);

            $self->_poll_child_exit($state, $child_pid, $started_child);

            1;
        };
        my $err = $@;

        unless ($ok) {
            $self->_emit_collector_error($err);
            $self->_kill_child($child_pid) if $child_pid && $started_child;
            last;
        }

        if ($state->{stdout_eof} && $state->{stderr_eof}) {
            if ($child_pid && $started_child && !$state->{child_exited}) {
                my $rv = waitpid($child_pid, 0);
                $state->{child_exit}   = $? if $rv == $child_pid;
                $state->{child_exited} = 1;
            }
            last;
        }
    }

    return ($buffer, $state->{child_exit});
}

# Termination state machine. Once we decide to take the child
# down (caught a signal, parent died, etc.) we send TERM and
# record a deadline; subsequent loop iterations keep draining
# the pipes so the child can finish whatever multipart write
# it was in the middle of. After the deadline the loop sends
# KILL. We never block-wait on the child here -- blocking would
# let the kernel pipe buffer fill while the child is still
# writing, and the resulting truncated multipart at EOF
# surfaces to the reader as "Incomplete message received before
# EOF" from Atomic::Pipe.
sub _init_termination_state {
    my $self = shift;
    return {
        draining      => 0,
        sent_term     => 0,
        sent_kill     => 0,
        kill_deadline => undef,
        kill_timeout  => $self->{+KILL_TIMEOUT} // 15,
    };
}

# Build the IO::Select set + per-handle bookkeeping for the
# collection loop. Returns a hashref state container shared with the
# loop helpers (sel, out_fh, err_fh, stdout_eof, stderr_eof,
# merge_outputs, cycle, child_exited, child_exit).
sub _init_collection_state {
    my $self = shift;
    my ($out_r, $err_r) = @_;

    my $stdout_eof = defined($out_r) ? 0 : 1;
    my $stderr_eof = defined($err_r) ? 0 : 1;

    my $merge_outputs =
           defined($out_r)
        && defined($err_r)
        && refaddr($out_r)
        && refaddr($err_r)
        && refaddr($out_r) == refaddr($err_r);
    $stderr_eof = 1 if $merge_outputs;

    my $sel    = IO::Select->new;
    my $out_fh = $stdout_eof ? undef : $self->_select_fh($out_r);
    my $err_fh = $stderr_eof ? undef : $self->_select_fh($err_r);
    $sel->add($out_fh) if defined $out_fh;
    $sel->add($err_fh) if defined $err_fh;

    return {
        cycle         => 0.2,
        sel           => $sel,
        out_fh        => $out_fh,
        err_fh        => $err_fh,
        stdout_eof    => $stdout_eof,
        stderr_eof    => $stderr_eof,
        merge_outputs => $merge_outputs,
        child_exited  => 0,
        child_exit    => undef,
    };
}

# Build an IO::Select for the IPC client's writable handles, or
# return undef when there is nothing to wait on.
sub _build_write_select {
    my $self = shift;
    my ($client) = @_;

    return undef unless $client && $client->have_writable_handles;
    my @wh = $client->writable_handles;
    return undef unless @wh;

    require IO::Select;
    my $write_sel = IO::Select->new;
    $write_sel->add(@wh);
    return $write_sel;
}

# Cap the select() wait when we're escalating so we don't
# oversleep the kill deadline.
sub _compute_loop_tick {
    my $self = shift;
    my ($cycle, $term) = @_;

    my $tick = $cycle;
    if (defined $term->{kill_deadline} && !$term->{sent_kill}) {
        my $remaining = $term->{kill_deadline} - time;
        $tick = $remaining if $remaining > 0 && $remaining < $tick;
        $tick = 0          if $remaining <= 0;
    }
    return $tick;
}

# Inspect signal-handler flag, parent-pids liveness, and the kill
# deadline; flips state in $term in place and delivers TERM/KILL to
# the child as appropriate.
sub _check_termination_signals {
    my $self = shift;
    my ($term, $got_signal_ref, $child_pid, $started_child, $child_exited) = @_;

    if ($$got_signal_ref && !$term->{draining}) {
        if ($child_pid && $started_child) {
            kill('TERM', $child_pid);
            $term->{sent_term}     = 1;
            $term->{kill_deadline} = time + $term->{kill_timeout};
        }
        $term->{draining} = 1;
    }

    if (!$term->{draining} && $self->{+PARENT_PIDS} && @{$self->{+PARENT_PIDS}}) {
        my $parent_gone = 0;
        for my $ppid (@{$self->{+PARENT_PIDS}}) {
            unless (pid_is_running($ppid)) {
                $parent_gone = 1;
                last;
            }
        }
        if ($parent_gone) {
            if ($child_pid && $started_child) {
                kill('TERM', $child_pid);
                $term->{sent_term}     = 1;
                $term->{kill_deadline} = time + $term->{kill_timeout};
            }
            $term->{draining} = 1;
        }
    }

    if (   $term->{draining}
        && defined $term->{kill_deadline}
        && !$term->{sent_kill}
        && !$child_exited
        && $child_pid
        && $started_child
        && time >= $term->{kill_deadline})
    {
        kill('KILL', $child_pid);
        $term->{sent_kill} = 1;
    }

    return;
}

# Drain whatever is currently readable from stdout/stderr pipes,
# updating EOF flags in $state and feeding items to _ingest_item.
sub _drain_input_handles {
    my $self = shift;
    my ($state, $out_r, $err_r, $buffer, $parser) = @_;

    unless ($state->{stdout_eof}) {
        for my $item ($self->_read_handle($out_r)) {
            if (!defined $item) {
                $state->{stdout_eof} = 1;
                $state->{sel}->remove($state->{out_fh}) if defined $state->{out_fh};
                last;
            }
            next unless $parser;
            $self->_ingest_item($buffer, 'stdout', $item, $state->{merge_outputs}, $parser);
        }
    }

    unless ($state->{stderr_eof}) {
        for my $item ($self->_read_handle($err_r)) {
            if (!defined $item) {
                $state->{stderr_eof} = 1;
                $state->{sel}->remove($state->{err_fh}) if defined $state->{err_fh};
                last;
            }
            next unless $parser;
            $self->_ingest_item($buffer, 'stderr', $item, $state->{merge_outputs}, $parser);
        }
    }

    return;
}

# Non-blocking child-status check: WNOHANG for our own forked
# children, pid_is_running() for cases where someone else owns the
# child (started_child false). Updates child_exited / child_exit in
# $state.
sub _poll_child_exit {
    my $self = shift;
    my ($state, $child_pid, $started_child) = @_;

    if ($child_pid && $started_child && !$state->{child_exited}) {
        my $rv = waitpid($child_pid, WNOHANG);
        if ($rv == $child_pid) {
            $state->{child_exited} = 1;
            $state->{child_exit}   = $?;
        }
    }

    if ($child_pid && !$started_child && !$state->{child_exited}) {
        $state->{child_exited} = 1 unless pid_is_running($child_pid);
    }

    return;
}

sub _finalize_collection {
    my $self = shift;
    my ($buffer, $parser, $child_exit) = @_;

    # Flush anything still sitting in the ordering buffer.
    $self->_flush_buffer($buffer, $parser) if $parser;

    if (defined $child_exit) {
        $self->{+CHILD_EXIT} = $child_exit;

        my $end_times   = [times()];
        my $end_stamp   = time;
        my $start_times = $self->{+_START_TIMES};
        my @cpu_times   = map { $end_times->[$_] - $start_times->[$_] } 0 .. 3;

        my $px = parse_exit($child_exit);
        $px->{times} = \@cpu_times;

        if (my $cf = $self->{+_CHILD_FORK_TIMES}) {
            $px->{child_times} = [map { $end_times->[$_] - $cf->[$_] } 0 .. 3];
        }
        if (defined(my $cs = $self->{+_CHILD_FORK_STAMP})) {
            $px->{child_wall} = $end_stamp - $cs;
        }

        # Stash for _write_report_row so the per-job report.jsonl.zst
        # carries the timing breakdown (times / child_times / child_wall).
        # Renderers used to read these out of the run service's run_mutation
        # snapshot; that channel is gone, so the artifact is now the
        # canonical home.
        $self->{+_PENDING_EXIT_TIMING} = {
            (defined $px->{times}       ? (times       => $px->{times})       : ()),
            (defined $px->{child_times} ? (child_times => $px->{child_times}) : ()),
            (defined $px->{child_wall}  ? (child_wall  => $px->{child_wall})  : ()),
        };

        my $exit_event = Test2::Harness2::Event->new(
            facet_data => {
                harness_process_exit => $px,
            },
        );
        $self->_process_event($exit_event);
    }

    # Auditor shutdown (Job collectors). May emit terminal events
    # and IPC.
    if (my $auditor = $self->{+AUDITOR}) {
        my @shutdown = grep { $_ } $auditor->shutdown($self);
        for my $e (@shutdown) {
            $self->_write_event($e);
        }
    }

    # Write the final report row, then close the writers.
    $self->_write_report_row($child_exit);

    # Tell the parent service we're going away. Done after the report
    # row is on disk so a parent reflecting the IPC into its own event
    # stream does so only once the child's report.jsonl.zst is final.
    # The IPC outbox is drained by _exit_mirroring_child before _exit.
    $self->_emit_collector_end($child_exit);

    for my $slot (+_EVENTS_WRITER, +_SPEC_WRITER, +_REPORT_WRITER) {
        my $w = delete $self->{$slot} or next;
        eval { $w->close; 1 };
    }

    # Clean exit of the top-level harness collector: drop the LIVE
    # sentinel so consumers tailing the dir can tell the harness
    # finished gracefully.
    $self->_remove_live_sentinel;

    return;
}

# Append the report.jsonl.zst row before exit:
#
#   Job:      auditor's final state hash, then any in-stream
#             collector_report facet content (rare for jobs but
#             allowed), then exit/exit_decoded/ended_at/pids.
#   Run/Svc:  collector_report facet content (the service-side
#             aggregate state), then exit/exit_decoded/ended_at/pids.
#
# Precedence (last writer wins on key collision):
#
#   collector exit-info > collector_report facet > auditor state.
#
# The collector is authoritative for exit/exit_decoded/ended_at/
# collector_pid/collected_pid; the service-emitted report carries
# service-side aggregate fields the collector cannot know.
sub _write_report_row {
    my $self = shift;
    my ($child_exit) = @_;

    my $w = $self->{+_REPORT_WRITER} or return;

    my %row;

    # 1. Auditor state (Jobs only) -- lowest precedence.
    if ($self->{+TYPE} eq 'Job' && (my $auditor = $self->{+AUDITOR})) {
        my $state = $self->_auditor_final_state($auditor);
        if ($state) {
            %row = (%row, %$state);
        }
    }

    # 2. In-stream collector_report facet content (Run/Service mostly,
    #    but Jobs may carry one too). Overrides auditor state on key
    #    collision.
    if (my $pending = $self->{+_PENDING_COLLECTOR_REPORT}) {
        %row = (%row, %$pending);
    }

    # 3. Collector-supplied exit info -- highest precedence; the
    #    collector is the authoritative source for these.
    $row{exit}          = $child_exit;
    $row{exit_decoded}  = defined($child_exit) ? parse_exit($child_exit) : undef;
    $row{ended_at}      = time;
    $row{collector_pid} = $$;
    $row{collected_pid} = $self->{+CHILD_PID} if defined $self->{+CHILD_PID};

    # Timing breakdown captured at child reap. Renderers used to read
    # times / child_times / child_wall out of the run service's
    # run_mutation snapshot; the per-job report.jsonl.zst is now their
    # canonical home.
    if (my $timing = $self->{+_PENDING_EXIT_TIMING}) {
        $row{$_} = $timing->{$_} for keys %$timing;
    }

    require Test2::Harness2::Util::JSON;
    $w->say(Test2::Harness2::Util::JSON::encode_json(\%row));
}

# Best-effort projection of an Auditor::Test instance's final state
# into a plain hashref. Prefers final_state() when the auditor exposes
# it; falls back to reading public accessors one by one for older /
# minimal auditor classes.
sub _auditor_final_state {
    my ($self, $auditor) = @_;
    return undef unless $auditor;

    return $auditor->final_state if $auditor->can('final_state');

    my %state;
    $state{pass}            = $auditor->pass ? 1 : 0    if $auditor->can('pass');
    $state{fail_count}      = $auditor->fail_count      if $auditor->can('fail_count');
    $state{pass_count}      = $auditor->pass_count      if $auditor->can('pass_count');
    $state{assertion_count} = $auditor->assertion_count if $auditor->can('assertion_count');
    $state{exit}            = $auditor->exit            if $auditor->can('exit');
    if ($auditor->can('plan')) {
        my $plan = $auditor->plan;
        $state{plan} = $plan if defined $plan;
    }
    if ($auditor->can('halt')) {
        my $halt = $auditor->halt;
        $state{halt} = $halt if defined $halt;
    }
    return \%state;
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
    elsif ($self->{+LAUNCH_CALLBACK}) {
        push @parts => 'launch_callback';
    }
    elsif (defined $self->{+OUT_FH} || defined $self->{+ERR_FH}) {
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

    my ($out_r, $out_w) = Atomic::Pipe->pair(mixed_data_mode => 1, atomic_pipe_compression_args());
    my ($err_r, $err_w) = Atomic::Pipe->pair(mixed_data_mode => 1, atomic_pipe_compression_args());

    open(my $orig_stdout, '>&', \*STDOUT) or croak "Could not clone STDOUT: $!";
    open(my $orig_stderr, '>&', \*STDERR) or croak "Could not clone STDERR: $!";

    my $pid =
        IS_WIN32
        ? $self->_launch_child_win32($out_r, $out_w, $err_r, $err_w, $orig_stdout, $orig_stderr)
        : $self->_launch_child_unix($out_r, $out_w, $err_r, $err_w, $orig_stdout, $orig_stderr);

    $out_w->close();
    $err_w->close();

    close($orig_stdout);
    close($orig_stderr);

    return ($pid, $out_r, $err_r);
}

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
    my $cb  = $self->{+LAUNCH_CALLBACK};

    $self->{+_CHILD_FORK_TIMES} = [times()];
    $self->{+_CHILD_FORK_STAMP} = time;

    my $pid = fork() // die "Failed to fork child process: $!";

    if (!$pid) {
        $out_r->close();
        $err_r->close();

        swap_io(\*STDOUT, $out_w->wh);
        swap_io(\*STDERR, $err_w->wh);
        STDOUT->autoflush(1);
        STDERR->autoflush(1);

        close($orig_stdout);
        close($orig_stderr);

        if ($self->{+NEW_PGROUP}) {
            POSIX::setpgid(0, 0) or warn "setpgid(0,0) failed: $!";
        }

        if (my $child_cwd = $self->{+CWD}) {
            chdir($child_cwd) or die "Failed to chdir to '$child_cwd': $!";
        }

        my %env = $self->_child_env_overrides;
        # Jump-out point for preloaded tests. The callback owns
        # everything that happens next: it inherits the parent
        # service's preloaded %INC, completes whatever process
        # reset it needs, and then either Long::Jumps out to a
        # setjump anchor in the surrounding preload service (the
        # normal goto::file pathway) or exits directly. If it
        # returns to us we treat that as a contract violation and
        # exit non-zero loudly so the failure surfaces in the
        # collector's log instead of going silent.
        #
        # Dismiss the _spawn_collector Scope::Guard before invoking
        # the callback. The guard's POSIX::_exit(255) destructor
        # would otherwise fire when the callback eventually exits
        # via Test2's END finalizer, pre-empting Stream2's plan +
        # assertion-count flush.
        if ($cb) {
            @ENV{keys %env} = values %env;
            if (my $g = delete $self->{_collector_guard}) { $g->dismiss }
            $cb->();
            print STDERR "Test2::Harness2::Collector: launch_callback returned without exiting\n";
            POSIX::_exit(255);
        }

        local @ENV{keys %env} = values %env;
        exec(@$cmd) or croak "Failed to exec '@$cmd': $!";
    }

    open(STDOUT, '>&', $orig_stdout) or croak "Could not restore STDOUT: $!";
    open(STDERR, '>&', $orig_stderr) or croak "Could not restore STDERR: $!";

    return $pid;
}

sub _wrap_handle {
    my $self = shift;
    my ($handle) = @_;

    return $handle if blessed($handle) && $handle->isa('Atomic::Pipe');

    if (-p $handle) {
        my $ap = Atomic::Pipe->from_fh('<&', $handle);
        $ap->set_mixed_data_mode();
        apply_atomic_pipe_compression($ap);
        return $ap;
    }

    return Test2::Harness2::Collector::Util::FileLineReader->new($handle);
}

sub _select_fh {
    my $self = shift;
    my ($handle) = @_;
    return undef unless defined $handle;
    return $handle->rh   if blessed($handle) && $handle->isa('Atomic::Pipe');
    return $handle->{fh} if blessed($handle) && $handle->isa('Test2::Harness2::Collector::Util::FileLineReader');
    return undef;
}

sub _read_handle {
    my $self = shift;
    my ($handle) = @_;

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

    return $handle->read_lines();
}

sub _ingest_item {
    my $self = shift;
    my ($buffer, $stream, $item, $merge_outputs, $parser) = @_;

    my ($type, $data, $compressed) = @$item;
    my $stamp = time;

    if ($type eq 'message') {
        my $decoded;
        unless (eval { $decoded = decode_json($data); 1 }) {
            my $err = $@;
            $self->_emit_collector_error(
                "Failed to decode JSON burst on $stream: $err",
                invalid_json => $data,
            );
            return;
        }

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

    chomp $data;
    push @{$buffer->{$stream}} => [$stamp, line => $data];

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
                    my $event = $parser->parse_io(
                        stream     => $stream,
                        event      => $val,
                        stamp      => $stamp,
                        compressed => $compressed,
                    );
                    $self->_process_event($event) if $event;
                }

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

# Pipeline: parser -> [auditor for Job] -> write_phase.
sub _process_event {
    my $self = shift;
    my ($event) = @_;

    return unless $event;

    my @events;
    if (my $auditor = $self->{+AUDITOR}) {
        @events = $auditor->audit_event($event);
    }
    else {
        @events = ($event);
    }

    for my $e (@events) {
        next unless $e;
        $self->_write_event($e);
    }
}

# Write phase. Extract any base64 attachment hashes into
# <base>/attachments/, capture any collector_report facet content
# (services emit one final event with collector_report containing
# service-side aggregate state for the report row), mutate the
# event facet to point at archive_path (stripping data/encoding),
# then append the rewritten event as JSON to events.jsonl.zst.
sub _write_event {
    my $self = shift;
    my ($event) = @_;
    return unless $event;

    my $w = $self->{+_EVENTS_WRITER} or return;

    $self->_capture_collector_report($event);
    $self->_strip_trace_full_caller($event);
    $self->_extract_attachments($event);

    my $json = ref($event) && $event->can('as_json') ? $event->as_json : do {
        require Test2::Harness2::Util::JSON;
        Test2::Harness2::Util::JSON::encode_json($event);
    };

    $w->say($json);
}

# Stash any in-stream collector_report facet content for merging into
# report.jsonl.zst at exit. Last writer wins -- a service that emits
# multiple collector_report facets has its final one captured. The
# event is still written to events.jsonl.zst normally; the stash is
# in addition.
sub _capture_collector_report {
    my $self = shift;
    my ($event) = @_;
    return unless $event;

    my $fd;
    if (blessed($event)) {
        $fd = $event->facet_data;
    }
    elsif (ref($event) eq 'HASH') {
        $fd = $event->{facet_data};
    }
    return unless ref($fd) eq 'HASH';

    my $cr = $fd->{collector_report};
    return unless ref($cr) eq 'HASH';

    # Shallow copy so the on-disk event hash and the stash diverge
    # cleanly if any later code mutates one.
    $self->{+_PENDING_COLLECTOR_REPORT} = {%$cr};

    return;
}

# Test2::API populates trace.full_caller with the full 11-element
# caller() array (including the warning_bits string and a hint hash
# ref) on every context. The harness has no consumer for it -- the
# 4-element trace.frame is what renderers and auditors use -- and
# leaving it in bloats every events.jsonl.zst row. Strip it before
# the event is serialized.
sub _strip_trace_full_caller {
    my $self = shift;
    my ($event) = @_;
    return unless $event;

    my $fd;
    if (blessed($event)) {
        $fd = $event->facet_data;
    }
    elsif (ref($event) eq 'HASH') {
        $fd = $event->{facet_data};
    }
    return unless ref($fd) eq 'HASH';

    my $mutated = _strip_trace_full_caller_from_facets($fd);

    if ($mutated && ref($event) && $event->can('clear_compressed_form')) {
        $event->clear_compressed_form;
    }

    return;
}

# Recursively strip trace.full_caller from a facet_data hash. Subtest
# events carry nested child events under parent.children whose own
# trace facets need the same treatment.
sub _strip_trace_full_caller_from_facets {
    my ($fd) = @_;
    return 0 unless ref($fd) eq 'HASH';

    my $mutated = 0;

    if (ref($fd->{trace}) eq 'HASH' && exists $fd->{trace}{full_caller}) {
        delete $fd->{trace}{full_caller};
        $mutated = 1;
    }

    my $parent = $fd->{parent};
    if (ref($parent) eq 'HASH' && ref($parent->{children}) eq 'ARRAY') {
        for my $child (@{$parent->{children}}) {
            $mutated = 1 if _strip_trace_full_caller_from_facets($child);
        }
    }

    return $mutated;
}

# Extensions whose payload is already compressed and should NOT get an
# additional .zst wrapper. Keep this list in sync with the answer to
# LOGGER_ARTIFACT_REFACTOR2 §195.
my %ALREADY_COMPRESSED = map { $_ => 1 } qw(
    jpg jpeg png gif webp avif heic
    mp4 mov webm mkv
    mp3 ogg oga opus flac aac m4a
    zst gz xz bz2 zip 7z rar
);

sub _attachment_already_compressed {
    my ($self, $filename) = @_;
    return 0 unless defined $filename;
    return 0 unless $filename =~ /\.([A-Za-z0-9]+)\z/;
    return $ALREADY_COMPRESSED{lc $1} ? 1 : 0;
}

# Build a safe on-disk filename component. Strip any directory parts
# the user may have put in 'filename' so we never escape the
# attachments/ directory; replace anything ugly.
sub _attachment_safe_name {
    my ($self, $filename) = @_;
    return 'attachment' unless defined $filename && length $filename;

    # Strip any path separators -- keep only the basename component.
    $filename =~ s{.*[/\\]}{}s;

    # Replace control characters and embedded NULs.
    $filename =~ s/[\x00-\x1F\x7F]/_/g;

    # Empty after stripping? Fall back.
    return 'attachment' unless length $filename;

    return $filename;
}

# Initialize the per-collector attachment counter from any pre-existing
# attachments under <base>/attachments/. Pre-populated so a restarted
# collector pointed at an existing logdir does not clobber prior files.
sub _init_attachment_counter {
    my $self = shift;
    return $self->{+_ATTACHMENT_COUNTER} if defined $self->{+_ATTACHMENT_COUNTER};

    my $dir  = $self->base_dir . '/attachments';
    my $high = 0;

    if (opendir(my $dh, $dir)) {
        while (defined(my $entry = readdir($dh))) {
            next if $entry eq '.' || $entry eq '..';
            next unless $entry =~ /^(\d+)-/;
            my $n = 0 + $1;
            $high = $n if $n > $high;
        }
        closedir($dh);
        # Dir already exists, so don't try to make_path again later.
        $self->{+_ATTACHMENT_DIR_MADE} = 1;
    }

    return $self->{+_ATTACHMENT_COUNTER} = $high;
}

sub _next_attachment_index {
    my $self = shift;
    $self->_init_attachment_counter;
    return ++$self->{+_ATTACHMENT_COUNTER};
}

sub _attachment_prefix {
    my ($self, $n) = @_;
    return $n > 9999 ? "$n" : sprintf('%04d', $n);
}

sub _attachments_dir {
    my $self = shift;
    my $dir  = $self->base_dir . '/attachments';
    unless ($self->{+_ATTACHMENT_DIR_MADE}) {
        make_path($dir);
        $self->{+_ATTACHMENT_DIR_MADE} = 1;
    }
    return $dir;
}

# An attachment is a hash with all three of: filename, data, encoding.
sub _looks_like_attachment {
    my ($self, $val) = @_;
    return 0 unless ref($val) eq 'HASH';
    return 0 unless defined $val->{filename} && !ref $val->{filename};
    return 0 unless defined $val->{data}     && !ref $val->{data};
    return 0 unless defined $val->{encoding} && !ref $val->{encoding};
    return 1;
}

# Walk the event's facet_data; for each attachment hash detected
# anywhere inside (any facet, any depth into list-style facets),
# extract the bytes and mutate the hash in place.
sub _extract_attachments {
    my $self = shift;
    my ($event) = @_;
    return unless $event;

    my $fd;
    if (blessed($event)) {
        $fd = $event->facet_data;
    }
    elsif (ref($event) eq 'HASH') {
        $fd = $event->{facet_data};
    }
    return unless ref($fd) eq 'HASH';

    my $mutated = 0;
    for my $facet_key (keys %$fd) {
        my $facet = $fd->{$facet_key};
        if (ref($facet) eq 'ARRAY') {
            for my $i (0 .. $#$facet) {
                my $entry = $facet->[$i];
                next unless $self->_looks_like_attachment($entry);
                $self->_extract_one_attachment($entry);
                $mutated = 1;
            }
        }
        elsif (ref($facet) eq 'HASH') {
            if ($self->_looks_like_attachment($facet)) {
                $self->_extract_one_attachment($facet);
                $mutated = 1;
            }
        }
    }

    # Drop any cached JSON / compressed-form so the rewritten event
    # serializes to the latest hash.
    if ($mutated && ref($event) && $event->can('clear_compressed_form')) {
        $event->clear_compressed_form;
    }

    return;
}

# Extract one attachment hash in place. Decodes the base64 data, picks
# a unique on-disk filename, writes the bytes (zstd-compressed unless
# the extension says they're already compressed), and rewrites the
# input hash to drop data/encoding and add archive_path.
sub _extract_one_attachment {
    my $self = shift;
    my ($att) = @_;

    my $orig_filename = $att->{filename};
    my $encoding      = $att->{encoding};
    my $b64           = $att->{data};

    my $bytes;
    if (lc $encoding eq 'base64') {
        $bytes = decode_base64($b64);
    }
    else {
        # Unknown encoding -- leave as-is; better to keep the data
        # in-event than to silently drop it.
        return;
    }

    my $idx        = $self->_next_attachment_index;
    my $prefix     = $self->_attachment_prefix($idx);
    my $safe_name  = $self->_attachment_safe_name($orig_filename);
    my $compressed = !$self->_attachment_already_compressed($orig_filename);

    my $on_disk_name = "$prefix-$safe_name";
    $on_disk_name .= '.zst' if $compressed;

    my $dir  = $self->_attachments_dir;
    my $path = "$dir/$on_disk_name";

    my $payload = $compressed ? compress_blob($bytes) : $bytes;
    write_file_atomic($path, $payload);

    # Path inside the log tree (relative to logdir root).
    my $base_rel = collector_base_dir(
        type    => $self->{+TYPE},
        id      => $self->{+ID},
        run_id  => $self->{+RUN_ID},
        job_try => $self->{+JOB_TRY},
    );
    my $archive_path = "$base_rel/attachments/$on_disk_name";

    # Mutate the facet hash in place. Preserve filename / details /
    # is_image; strip data + encoding; add archive_path.
    delete $att->{data};
    delete $att->{encoding};
    $att->{archive_path} = $archive_path;

    return;
}

# Public alias for code that wants to push synth events into the
# write phase (e.g. service code emitting collector_report). Bypasses
# the auditor (synth events are already final).
sub write_event {
    my ($self, $event) = @_;
    return $self->_write_event($event);
}

sub _exit_mirroring_child {
    my $self = shift;
    my ($collector_ok) = @_;

    if (my $client = $self->{_ipc_client}) {
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

    return $self->_kill_child_win32($pid) if IS_WIN32;

    return kill_child($pid, kill_timeout => $self->{+KILL_TIMEOUT});
}

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

    my @child_fork_times = times();
    my $child_fork_stamp = time;

    my $pid = fork() // die "Failed to fork for interpose: $!";

    if ($pid) {
        $params{pid}               = $pid;
        $params{_child_fork_times} = \@child_fork_times;
        $params{_child_fork_stamp} = $child_fork_stamp;
        $class->_interpose_parent(\%params);
    }

    $class->_interpose_child(\%params);

    if (defined $jump_to) {
        Long::Jump::longjump($jump_to, $jump_payload);
        POSIX::_exit(255);
    }

    return;
}

sub _interpose_parent {
    my ($class, $params) = @_;

    my $guard = Scope::Guard->new(sub { POSIX::_exit(255) });

    my $out_w       = delete $params->{out_w};
    my $err_w       = delete $params->{err_w};
    my $orig_stdout = delete $params->{orig_stdout};
    my $orig_stderr = delete $params->{orig_stderr};

    $out_w->close();
    $err_w->close();

    open(STDOUT, '>&', $orig_stdout) or croak "Could not restore STDOUT: $!";
    open(STDERR, '>&', $orig_stderr) or croak "Could not restore STDERR: $!";
    close($orig_stdout);
    close($orig_stderr);

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

    $ENV{T2_HARNESS2_PIPE_COUNT} = 2;
}

# Used by Role::Tiny check above (auditor validation).
require Role::Tiny;

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector - Single collector class for tests, runs, and services.

=head1 DESCRIPTION

The collector is a single non-subclassed class that takes a
C<type =E<gt> 'Job' | 'Run' | 'Service'> slot and writes its own log
artifacts directly to disk. The per-collector trio
(C<spec.jsonl.zst>, C<events.jsonl.zst>, C<report.jsonl.zst>) is
written by the collector itself under its base directory.

=head1 PIPELINE

    parser -> [Auditor::Test on type=Job] -> write_phase

C<parser> ingests structured events from the collected child's
stdout / stderr (TAP, structured events, etc.). For C<type=Job>
the events flow through an L<Test2::Harness2::Collector::Auditor::Test>
instance, which tracks pass/fail state, validates the assertion /
plan / subtest invariants, and emits the upward-facing IPC
transitions (C<test_job_started>, C<test_job_diagnosing>,
C<test_job_failing>, C<test_job_completed>, C<job_release>) that
the L<TestObserver> module used to handle in the previous design.

For C<type=Run> and C<type=Service> the auditor is skipped: those
are dumb pass-throughs because their state lives in the collected
service process itself (the run service / global service), not in
the collector. State-transition events for runs and services are
emitted by the service process directly into its own outgoing
event stream and ingested by the run collector like any other
event.

C<write_phase> decodes any C<harness_attachment> facets, persists
their payloads under C<E<lt>baseE<gt>/attachments/E<lt>filenameE<gt>>,
substitutes a path reference back into the event, and appends the
event to C<events.jsonl.zst>.

=head1 ON-DISK LAYOUT PRODUCED

Path templates per L<Test2::Harness2::LogLayout>:

    services/<name>/                          (type=Service, no run_id)
    runs/<run_id>/services/<name>/            (type=Service, with run_id)
    runs/<run_id>/                            (type=Run)
    runs/<run_id>/jobs/<job_id>/<job_try>/    (type=Job)

Under each base, the collector writes:

    spec.jsonl.zst            one row, written at startup
    events.jsonl.zst          append-only, one or more rows
    report.jsonl.zst          one row, written at shutdown
    attachments/<filename>    optional, per write_phase decode

The harness collector additionally writes / removes a C<LIVE>
sentinel file at the log root: present while the harness is
running, removed on clean shutdown, absent on crash. The reader
uses the sentinel to disambiguate "live, expect more bytes" from
"sealed".

=head1 IPC EMISSIONS

On startup the collector sends a C<collector_start> message to its
parent service; on shutdown a C<collector_end>. The parent service
reflects each into its own outgoing events stream as
C<harness_collector_start> / C<harness_collector_end> events, which
is what the reader's depth-first iterator pivots on to push and
pop child readers.

For C<type=Job>, the Auditor additionally emits
C<test_job_started> / C<test_job_diagnosing> / C<test_job_failing>
/ C<test_job_completed> / C<job_release> through the same IPC
client.

=head1 ATTRIBUTES

=over 4

=item type (required)

One of C<'Job'>, C<'Run'>, C<'Service'>.

=item id (required)

Identifier of the collected thing. Service name (string) for
type=Service; ord int for type=Run/Job.

=item run_id

Run identifier (ord int). Defined for type=Run, type=Job, and
run-scoped services. Undef for global services and the harness's
own collector.

=item job_try

Integer (default 0). Only meaningful for type=Job.

=item logdir (required)

Absolute path of the workdir's logs/ directory. The collector base
dir is computed under this.

=item spec

Hashref of constructor arguments / metadata for the collected
thing. Written verbatim to spec.jsonl.zst on startup, with
collector pid + identity stamped on automatically.

=item auditor

Test2::Harness2::Role::Auditor spec (class name, [class, args], or
blessed instance). Only meaningful for type=Job; ignored otherwise.

=item launch

Arrayref command to spawn as the collected child process.

=item ipc_parent / ipc_run / ipc_harness

Bus names for the relevant peer services. Used by the auditor to
emit upward-facing IPC.

=back

=head1 SOURCE

L<https://github.com/Test-More/Test2-Harness>

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

See L<https://dev.perl.org/licenses/>

=cut
