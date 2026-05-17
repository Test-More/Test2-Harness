package Test2::Harness2::PreloadService;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use File::Basename qw/dirname/;
use POSIX ();
use Scalar::Util qw/blessed/;

use Test2::Harness2::Util qw/mod2file/;

use Object::HashBase qw{
    <preload_name
    <modules
    <scope
    <run_id
    <is_role_consumer
    <log_path
    <ipcm_info
    <workdir
    <reloader_class
    <reloader_args
    kill_timeout
    state
    own_pgroup
    watch_pids
    +pid
    +_name
    +_reloader
    +_pending_spawns
};

use Role::Tiny::With;
# Role::Service transitively consumes Role::ResourceService and
# IPC::Manager::Role::Service, so a single `with` here satisfies the
# host's Role::ResourceService check too.
with 'Test2::Harness2::Role::Service';

sub init {
    my $self = shift;

    # Accept the host's 'name' construction arg as preload_name; the
    # bus-level service name is derived (preload-<name> for global,
    # preload-<run_id>-<name> for run scope) so the scheduler can
    # address a preload by its preload_name + scope tuple while the
    # host-level uniqueness check sees the namespaced name.
    if (defined $self->{name} && !defined $self->{+PRELOAD_NAME}) {
        $self->{+PRELOAD_NAME} = delete $self->{name};
    }

    croak "'name' is a required attribute"
        unless defined $self->{+PRELOAD_NAME} && length $self->{+PRELOAD_NAME};
    croak "'modules' is a required attribute (arrayref, may be empty)"
        unless defined $self->{+MODULES} && ref($self->{+MODULES}) eq 'ARRAY';

    $self->{+SCOPE}            //= 'global';
    $self->{+IS_ROLE_CONSUMER} //= 0;
    $self->{+KILL_TIMEOUT}     //= 15;
    $self->{+STATE}            //= 'running';
    # WATCH_PIDS is filled in from service_on_start (after the fork)
    # via getppid(); calling getppid() here would pick up the
    # pre-fork parent (the host harness's parent process) instead of
    # the harness service itself.
    $self->{+WATCH_PIDS}       //= [];
    $self->{+OWN_PGROUP}       //= 0;
    $self->{+_PENDING_SPAWNS}  //= {};

    croak "'scope' must be 'global' or 'run'"
        unless $self->{+SCOPE} eq 'global' || $self->{+SCOPE} eq 'run';
    croak "scope='run' requires 'run_id'"
        if $self->{+SCOPE} eq 'run' && !(defined $self->{+RUN_ID} && length $self->{+RUN_ID});

    # workdir defaults to the directory containing log_path; Role::Service
    # surfaces it on the service_started event, no on-disk usage of our
    # own.
    if (!defined $self->{+WORKDIR}) {
        $self->{+WORKDIR} = defined $self->{+LOG_PATH} ? dirname($self->{+LOG_PATH}) : '.';
    }

    # Cache the bus-level name on first read.
    $self->{+_NAME} = $self->_compute_name;
}

sub _compute_name {
    my $self = shift;
    my $pn   = $self->{+PRELOAD_NAME};
    return "preload-$pn" if $self->{+SCOPE} eq 'global';
    return "preload-$self->{+RUN_ID}-$pn";
}

sub name { $_[0]->{+_NAME} //= $_[0]->_compute_name }

# Role::Service emits service_started carrying these extra fields so a
# downstream reader of the resource service's log file can tell which
# preload it is and whether the preload is a Role::Preload consumer.
sub service_started_fields {
    my $self = shift;
    return (
        preload_name     => $self->{+PRELOAD_NAME},
        preload_scope    => $self->{+SCOPE},
        preload_modules  => [@{$self->{+MODULES}}],
        is_role_consumer => $self->{+IS_ROLE_CONSUMER} ? 1 : 0,
        ($self->{+SCOPE} eq 'run' ? (preload_run_id => $self->{+RUN_ID}) : ()),
    );
}

# Minimal stub. Real implementation lands once the spawn pathway is in
# place; this will return the pids of any in-flight spawn-in-progress
# workers.
sub hard_stop_pids {
    my $self = shift;
    return ();
}

# Resource services receive log_path from the host; until the BEGIN
# block lifecycle lands the service has no STDOUT-bound EventEmitter,
# so emit_service_event is a no-op. The spawn-pathway task wires this
# up to write JSONL into log_path.
sub emit_service_event { }

# When this preload was built from a Role::Preload consumer (the -P
# classifier set is_role_consumer => 1), MODULES carries exactly one
# entry: the consumer class. Returns the class name in that case,
# undef otherwise.
sub _role_consumer_class {
    my $self = shift;
    return undef unless $self->{+IS_ROLE_CONSUMER};
    my $mods = $self->{+MODULES} // [];
    return undef unless @$mods;
    return $mods->[0];
}

# Sequential require of each module in $self->modules. Croaks with a
# clear message naming the preload + failing module + underlying
# error. Single source of truth for the require step so the harness's
# service_on_start (which awaits initial-load readiness) and a future
# reload-restart can both share the same code path.
#
# For Role::Preload consumers the require + initialization step is
# delegated to the consumer's do_preload (default supplied by the
# role itself). That call runs in the service process after the
# class has been loaded once via _require_module, so any custom
# bootstrap a consumer wants to do happens before preload_ready fires.
sub do_preload {
    my $self = shift;

    if (my $class = $self->_role_consumer_class) {
        my $ok  = eval { $self->_require_module($class); 1 };
        my $err = $@;
        unless ($ok) {
            my $preload = $self->{+PRELOAD_NAME};
            chomp(my $e = $err);
            croak "Failed to load module '$class' for preload '$preload': $e";
        }

        $ok  = eval { $class->do_preload($self); 1 };
        $err = $@;
        unless ($ok) {
            my $preload = $self->{+PRELOAD_NAME};
            chomp(my $e = $err);
            croak "do_preload failed for preload '$preload' (class '$class'): $e";
        }

        return 1;
    }

    for my $mod (@{$self->{+MODULES}}) {
        my $ok  = eval { $self->_require_module($mod); 1 };
        my $err = $@;
        next if $ok;

        my $preload = $self->{+PRELOAD_NAME};
        chomp(my $e = $err);
        croak "Failed to load module '$mod' for preload '$preload': $e";
    }

    return 1;
}

# Fire a Role::Preload lifecycle hook on the consumer class, if any.
# Hooks are class-method calls so consumers do not need a constructor;
# state across hooks lives in package globals on the consumer side.
# A hook exception is logged via warn but does not abort the spawn --
# pre_fork failure should not strand the harness's launch_job.
sub _fire_role_hook {
    my ($self, $hook, $payload) = @_;
    my $class = $self->_role_consumer_class or return;
    return unless $class->can($hook);

    my $ok = eval { $class->$hook($self, $payload); 1 };
    unless ($ok) {
        my $err = $@;
        chomp(my $e = $err);
        my $name = $self->{+PRELOAD_NAME};
        warn "Role::Preload hook '$hook' for preload '$name' (class '$class') failed: $e\n";
    }
    return;
}

sub _require_module {
    my ($self, $mod) = @_;
    require( mod2file($mod) );
    return 1;
}

# Role::Service calls this from run_on_start after the pgroup /
# subreaper / service_started steps. We use it to pre-load the
# requested modules and announce readiness to the harness over the IPC
# bus. A do_preload failure propagates out of service_on_start, which
# unwinds the service's run loop and exits non-zero -- the host's
# Role::ResourceServiceHost then flips the matching Resource::Preload
# to permanent_broken (initial-load failure -> not restartable on this
# service class).
sub service_on_start {
    my $self = shift;

    # Now that we're in the forked child, getppid() returns the
    # harness service that spawned us. Adding it to watch_pids gives
    # IPC::Manager's per-tick poll a "parent gone, time to wind
    # down" signal -- without it the preload service has no
    # termination path (hard_stop_pids is empty so a terminate
    # request's escalator no-ops, and the harness's perform_hard_stop
    # waits forever for us).
    my $ppid = POSIX::getppid();
    push @{$self->{+WATCH_PIDS}}, $ppid
        if $ppid && !grep { $_ == $ppid } @{$self->{+WATCH_PIDS}};

    $self->do_preload;

    # Instantiate the reloader (if any) after do_preload so the
    # reloader sees the fully-populated %INC. Failure here is
    # non-fatal: the preload still works, just without hot reload.
    $self->_instantiate_reloader;

    my %payload = (
        kind         => 'preload_ready',
        preload_name => $self->{+PRELOAD_NAME},
        scope        => $self->{+SCOPE},
        ($self->{+SCOPE} eq 'run' ? (run_id => $self->{+RUN_ID}) : ()),
    );

    my $client = $self->client;
    $client->send_message('harness', \%payload) if $client;

    return;
}

# Build a reloader instance from the spec the harness shipped at
# service-spawn time. spec shape: { class => 'Test2::Harness2::Reloader::...',
# args => { ... } }. Falls back to a no-op if no class is given or
# the require fails -- the preload itself is still valid without a
# reloader.
sub _instantiate_reloader {
    my $self = shift;
    my $class = $self->{+RELOADER_CLASS};
    return unless defined $class && length $class;

    my $args = $self->{+RELOADER_ARGS} // {};
    $args = {} unless ref($args) eq 'HASH';

    my $ok  = eval { require( $class =~ s{::}{/}gr . '.pm' ); 1 };
    my $err = $@;
    unless ($ok) {
        warn "PreloadService: could not load reloader '$class': $err\n";
        return;
    }

    my $rel;
    $ok  = eval { $rel = $class->new(%$args); 1 };
    $err = $@;
    unless ($ok) {
        warn "PreloadService: could not instantiate reloader '$class': $err\n";
        return;
    }

    $self->{+_RELOADER} = $rel;
    return;
}

# IPC::Manager fires this every ~0.2s. Drive the reloader's tick from
# here; emit preload_broken / preload_ready transitions on state
# changes.
sub run_on_interval {
    my $self = shift;
    my $rel  = $self->{+_RELOADER} or return;

    my $was_error = $rel->last_error;
    eval { $rel->do_reload($self); 1 } or warn "reloader tick: $@";
    my $now_error = $rel->last_error;

    # Edge transitions only -- avoid spamming the harness with one
    # message per tick when the state is unchanged.
    if (!defined($was_error) && defined($now_error)) {
        $self->_send_preload_state('preload_broken', error => "$now_error");
    }
    elsif (defined($was_error) && !defined($now_error)) {
        $self->_send_preload_state('preload_ready');
    }

    return;
}

sub _send_preload_state {
    my ($self, $kind, %extra) = @_;
    my $client = $self->client or return;
    my %payload = (
        kind         => $kind,
        preload_name => $self->{+PRELOAD_NAME},
        scope        => $self->{+SCOPE},
        ($self->{+SCOPE} eq 'run' ? (run_id => $self->{+RUN_ID}) : ()),
        %extra,
    );
    eval { $client->send_message('harness', \%payload); 1 };
    return;
}

# Preloads are stateless and replaceable: a fresh restart re-requires
# the configured module set and resumes serving spawn requests. The
# harness's restart-spiral protection in
# Role::ResourceServiceHost::handle_resource_service_exit caps the
# attempt rate, so a permanently broken preload still flips to
# permanent_broken once it crosses the threshold rather than thrashing
# forever.
sub restartable { 1 }

# Tells IPC::Manager::Service::State::_ipcm_service to return rather
# than exit after run() returns. The test grandchild's longjump
# unwinds back to the setjump frame in run() (below), at which point
# we call goto::file->import to install a source filter and then
# return. _ipcm_service returns up to State::import, which is running
# at BEGIN time of the boot perl's -e snippet, and import returns;
# perl then resumes parsing -e -- but the source filter intercepts
# and feeds the test file's source into the parser instead. Test
# compiles in main with a shallow stack as if perl had been invoked
# with the test file directly.
sub run_returns_to_caller { 1 }

# Role::Service's request_handler_terminate runs perform_hard_stop
# (which flips state to 'terminating') but does not itself exit the
# IPC loop -- the loop's per-tick run_should_end is the signal. The
# preload service has no other "we're done" condition, so any
# 'terminating' state means: drop out of run() now.
sub run_should_end {
    my $self = shift;
    return 1 if ($self->{+STATE} // '') eq 'terminating';
    return 0;
}

# Override the role's run() to install a setjump 'preload_spawn'
# anchor around the IPC loop. fork() copies the C + Perl stack, so
# the grandchild test process inherits this setjump frame. When the
# grandchild's spawn_test callback finishes its Test2 reset it
# longjumps 'preload_spawn' with the test path as payload, unwinding
# back here. We then arrange for the surviving perl process to
# continue as if it had been invoked with the test file directly:
# goto::file installs a source filter that feeds the test's source
# into the parser on the way out through BEGIN.
sub run {
    my $self = shift;

    require Long::Jump;
    require goto::file;

    my $jumped = Long::Jump::setjump('preload_spawn', sub {
        # IPC::Manager::Role::Service provides the run loop;
        # Test2::Harness2::Role::Service composes it without
        # overriding. Call it directly so this override doesn't
        # recurse into itself via the composed copy on $self.
        IPC::Manager::Role::Service::run($self);
    });

    # Parent / clean-shutdown path: setjump body returned without a
    # longjump. Propagate role's intended exit code (0).
    return 0 unless defined $jumped;

    # setjump returns an arrayref of the args longjump was given
    # (after the tag). The post-refactor protocol carries a single
    # hashref: { kind => '<spawn_kind>', ...kind-specific... }. New
    # kinds (e.g. spawn_service) ride the same anchor by adding
    # branches below.
    my ($payload) = @$jumped;
    croak "preload longjump payload not a hashref"
        unless ref($payload) eq 'HASH';

    my $kind = $payload->{kind} // '';

    if ($kind eq 'spawn_test') {
        my $test_file_abs = $payload->{test_file_abs};
        croak "preload spawn_test payload missing test_file_abs"
            unless defined $test_file_abs && length $test_file_abs;
        $0 = $test_file_abs;
        goto::file->import($test_file_abs);
        return 0;
    }

    if ($kind eq 'spawn_service') {
        return _post_jump_spawn_service($self, $payload);
    }

    if ($kind eq 'spawn_script') {
        return _post_jump_spawn_script($self, $payload);
    }

    croak "unknown preload longjump payload kind: '$kind'";
}

# Async dispatch from harness. The harness calls $client->send_message
# (not send_request) so the message lands in run_on_general_message
# rather than the request/response pipeline. Route spawn_test kinds
# to request_handler_spawn_test from here.
sub run_on_general_message {
    my ($self, $msg) = @_;
    my $content = $msg->content;
    return unless ref($content) eq 'HASH';
    my $kind = $content->{kind} // $content->{request};
    return unless defined $kind;
    return $self->request_handler_spawn_test($content, $msg)    if $kind eq 'spawn_test';
    return $self->request_handler_spawn_service($content, $msg) if $kind eq 'spawn_service';
    return $self->request_handler_spawn_script($content, $msg)  if $kind eq 'spawn_script';
    return;
}

# IPC handler for spawn_test from the harness. Async: no response.
# Drives the full launch sequence:
#
#   1. Harness sends spawn_test (this method's $payload).
#   2. PreloadService calls Collector->spawn with a launch_callback
#      so the Collector's post-fork grandchild is in-process (no
#      exec) and still owns the preloaded %INC.
#   3. Collector forks twice: child = test-collector, grandchild =
#      test-process. The launch_callback runs in the grandchild.
#   4. The callback applies env, resets process-global state
#      (Test2 hub/formatter/exit-callbacks, $0, @ARGV, srand,
#      FindBin, Getopt::Long, empty-pattern //).
#   5. The callback calls Long::Jump::longjump 'preload_spawn'
#      with the test path as payload and never returns.
#   6. Control unwinds through Collector::_launch_child_unix,
#      Collector->spawn, request_handler_spawn_test,
#      run_on_general_message, and the role's run loop, landing
#      at the setjump 'preload_spawn' anchor in
#      PreloadService::run.
#   7. run() pulls the test path out of the setjump payload and
#      calls goto::file->import($test). The source filter is now
#      attached to the boot perl's still-being-parsed -e snippet.
#   8. run() returns 0. Because PreloadService sets
#      run_returns_to_caller true, _ipcm_service returns to
#      State::import; import returns; BEGIN ends.
#   9. Perl resumes parsing -e and the goto::file filter feeds
#      the test file's source instead. Test compiles in main
#      with a shallow stack, runs to completion, and exit() fires
#      Test2's END for the plan / assertion-count flush.
#
# The collector emits the standard test_job_started auditor event
# to the harness via its ipc_run wiring (pointing at the harness's
# bus name); the harness's JobTracker handle_test_job_started picks it up
# and populates the placeholder RUNNING_JOBS entry.
#
# Process tree after this returns to the IPC loop:
#
#   preload service (this process)
#    └── collector (fork of preload service via Collector->spawn)
#         └── test grandchild (fork of collector; runs the test
#                              via longjump 'preload_spawn' +
#                              goto::file)
sub request_handler_spawn_test {
    my ($self, $payload, $msg) = @_;

    croak "spawn_test payload missing test_file_abs"
        unless defined $payload->{test_file_abs};
    croak "spawn_test payload missing run_id"
        unless defined $payload->{run_id};
    croak "spawn_test payload missing job_id"
        unless defined $payload->{job_id};

    require Test2::Harness2::Collector;
    require Long::Jump;

    # Role::Preload pre_fork hook: in *this* (service) process before
    # any forks. Use it to warm caches / open shared handles the test
    # should inherit. Errors warn but do not abort.
    $self->_fire_role_hook(pre_fork => $payload);

    my $handle = $self->_collector_spawn_test($payload);
    return unless $handle;

    my $cpid = ref($handle) ? $handle->pid : undef;
    if (defined $cpid) {
        $self->{+_PENDING_SPAWNS}->{$cpid} = {
            run_id  => $payload->{run_id},
            job_id  => $payload->{job_id},
            started => time,
        };
    }

    return;
}

sub _collector_spawn_test {
    my ($self, $payload) = @_;

    # launch_callback runs in the Collector's post-fork child (the
    # test grandchild) with STDOUT/STDERR already swapped to the
    # collector's pipes. _test_grandchild_launch resets process and
    # Test2 state, fires pre_launch, then longjumps out to run()'s
    # setjump anchor; run() then goto::file's the test path.
    my $launch_cb = sub { $self->_test_grandchild_launch($payload) };

    # post_fork runs in the collector process (first child of this
    # service) right after fork. Only set when a role consumer exists;
    # Collector treats an unset callback as no-op.
    my $post_fork_cb;
    if ($self->_role_consumer_class) {
        my $self_ref = $self;
        $post_fork_cb = sub { $self_ref->_fire_role_hook(post_fork => $payload) };
    }

    my $env = ref($payload->{env}) eq 'HASH' ? $payload->{env} : {};
    my $auditor = $payload->{auditor};

    my $handle;
    my $ok = eval {
        $handle = Test2::Harness2::Collector->spawn(
            type            => 'Job',
            id              => $payload->{job_id},
            run_id          => $payload->{run_id},
            job_try         => $payload->{job_try} // 1,
            launch_callback => $launch_cb,
            ($post_fork_cb ? (post_fork_callback => $post_fork_cb) : ()),
            new_pgroup   => 1,
            parent_pids  => [$$],
            env_vars     => {%$env},
            logdir       => $payload->{logdir},
            ipcm_info    => $self->ipcm_info,
            ipc_parent   => $payload->{ipc_parent},
            ipc_run      => $payload->{ipc_run},
            ipc_harness  => $payload->{ipc_harness},
            kill_timeout => $payload->{kill_timeout},
            spec         => $payload->{spec} // {},
            (defined $auditor ? (auditor => $auditor) : ()),
            (defined $payload->{ch_dir} && length $payload->{ch_dir} ? (cwd => $payload->{ch_dir}) : ()),
        );
        1;
    };
    unless ($ok) {
        warn "spawn_test: Collector->spawn failed: $@";
        return undef;
    }
    return $handle;
}

# Test grandchild launch body, factored out of request_handler_spawn_test.
# Runs in the Collector's post-fork child with STDOUT/STDERR already
# swapped to the collector's pipes. Applies env, resets process and
# Test2 state, fires pre_launch, then longjumps out to run().
sub _test_grandchild_launch {
    my ($self, $payload) = @_;

    if (ref($payload->{env}) eq 'HASH') {
        $ENV{$_} = $payload->{env}->{$_} for keys %{$payload->{env}};
    }

    _reset_process_state();
    _reset_test2_state();

    # Pre-load Stream2 so the test child's first Test2::API context
    # triggers _finalize and reads T2_FORMATTER=Stream2 from %ENV
    # (applied above from the spawn payload).
    eval { require Test2::Formatter::Stream2 };

    # Empty-pattern reset so the test child's "" =~ /^/ semantics
    # match a freshly-started perl rather than inheriting the
    # preload service's last-match state. Must be dynamically scoped
    # at the grandchild level -- cannot be hoisted further.
    "" =~ /^/;

    # Role::Preload pre_launch hook: runs in the test grandchild
    # immediately before the longjump that hands control to the test
    # file. Use it for per-test state resets that the standard Test2
    # post-preload reset does not cover.
    $self->_fire_role_hook(pre_launch => $payload);

    Long::Jump::longjump('preload_spawn', {
        kind          => 'spawn_test',
        test_file_abs => $payload->{test_file_abs},
    });

    # Defensive fallback: longjump should always succeed because run()
    # installs the anchor before forks start happening. If it ever
    # does come back, treat as a contract bug and bail the grandchild.
    print STDERR "preload-spawn: longjump 'preload_spawn' returned (anchor missing?)\n";
    exit(255);
}

# Port from reference/old2/lib/Test2/Harness2/Collector/Preloaded.pm
# build_init_state.
sub _reset_process_state {
    @ARGV = ();
    srand();
    FindBin::init()                if defined &FindBin::init;
    Getopt::Long::ConfigDefaults() if defined &Getopt::Long::ConfigDefaults;
}

# Reset Test2's process-global state so the test child's hub, formatter,
# and assertion counters are fresh. post_preload_reset leaves a sticky
# FORMATTER slot and a populated Stack populated with hubs from the
# preload-service-side Test2 usage -- both need explicit clearing here
# so the test child rebuilds a fresh root hub via Stack::new_hub and
# picks up T2_FORMATTER=Stream2 at hub-build time. EXIT_CALLBACKS and
# friends also linger from preload-side plugins (SRand, etc.) and can
# confuse set_exit if left in place.
sub _reset_test2_state {
    return unless eval { require Test2::API; 1 };

    Test2::API::test2_post_preload_reset()
        if Test2::API->can('test2_post_preload_reset');

    if (my $stack = Test2::API::test2_stack()) {
        @$stack = ();
    }

    my $inst = do { no warnings 'once'; $Test2::API::INST } or return;
    $inst->{exit_callbacks}            = [];
    $inst->{post_load_callbacks}       = [];
    $inst->{context_init_callbacks}    = [];
    $inst->{context_acquire_callbacks} = [];
    $inst->{context_release_callbacks} = [];
    $inst->{pre_subtest_callbacks}     = [];
    $inst->{formatter}                 = undef;
}

# yath resource-spawn-via-preload: drop-and-reparent a service-class
# child off this preload. Double-forks so the grandchild's parent is
# reaped by us immediately, orphaning the grandchild to the harness
# (subreaper-capable Linux) or init (elsewhere). The grandchild then
# longjumps out of our run() loop into the setjump frame, which
# constructs the resource service class under a fresh IPC peer name
# and enters its own service loop.
sub request_handler_spawn_service {
    my ($self, $payload, $msg) = @_;

    for my $f (qw/class peer_name spawn_id notify_to/) {
        unless (defined $payload->{$f} && length $payload->{$f}) {
            warn "PreloadService::spawn_service: missing '$f' in payload; ignoring\n";
            return;
        }
    }

    my $child_a = fork;
    unless (defined $child_a) {
        warn "PreloadService::spawn_service: outer fork failed: $!\n";
        return;
    }
    if ($child_a) {
        waitpid $child_a, 0;
        return;
    }

    my $child_b = fork;
    if (!defined $child_b) {
        warn "PreloadService::spawn_service: inner fork failed: $!\n";
        POSIX::_exit(127);
    }
    if ($child_b) {
        POSIX::_exit(0);
    }

    # Grandchild: unwind out of PreloadService::run via setjump frame.
    require Long::Jump;
    Long::Jump::longjump('preload_spawn', {
        kind      => 'spawn_service',
        class     => $payload->{class},
        peer_name => $payload->{peer_name},
        ctor_args => $payload->{ctor_args} // {},
        notify_to => $payload->{notify_to},
        spawn_id  => $payload->{spawn_id},
    });

    print STDERR "PreloadService::spawn_service: longjump returned (anchor missing?)\n";
    POSIX::_exit(255);
}

# yath reload: drive the configured reloader one tick on demand and
# return the outcome synchronously. Without a reloader configured the
# request is a successful no-op: the preload has no dynamic state to
# reload, so reporting failure would mislead the operator into
# thinking something broke.
sub request_handler_reload {
    my ($self, $payload, $msg) = @_;
    my $rel = $self->{+_RELOADER}
        or return {ok => 1, noop => 1, message => 'no reloader configured'};
    my $ok  = eval { $rel->do_reload($self); 1 };
    my $err = $@;
    return $ok ? {ok => 1} : {ok => 0, error => "$err"};
}

# Runs in the grandchild (post-longjump) after the setjump frame has
# unwound PreloadService::run. Loads the resource service class, builds
# the service object under a fresh IPC peer name, registers the client
# (writing peer dir + pidfile), sends the resource_service_started
# notification to the harness, and enters the new service loop.
sub _post_jump_spawn_service {
    my ($self, $payload) = @_;

    my $class    = $payload->{class};
    my $modfile  = $class =~ s{::}{/}gr . '.pm';
    require $modfile;

    my $ctor_args = $payload->{ctor_args} // {};
    my $svc = $class->new(
        name      => $payload->{peer_name},
        ipcm_info => $self->ipcm_info,
        %$ctor_args,
    );

    # Force the client to materialise under the new peer name BEFORE
    # the notification fires, so the harness's reply-path (if any) and
    # any other peer that wants to address us by name has a peer dir
    # to find.
    my $client = $svc->client;

    $client->send_message(
        $payload->{notify_to},
        {
            kind        => 'resource_service_started',
            pid         => $$,
            via_preload => 1,
            spawn_id    => $payload->{spawn_id},
            peer_name   => $payload->{peer_name},
        },
    );

    $svc->run;

    POSIX::_exit(0);
}

# IPC handler for spawn_script from the harness. Async: no response.
# Validates the payload, double-forks (so the grandchild reparents off
# this PreloadService to init / the harness's subreaper), and longjumps
# to the setjump frame in run() with kind=spawn_script. The grandchild
# resumes in _post_jump_spawn_script with %INC still populated from
# the preload phase.
sub request_handler_spawn_script {
    my ($self, $payload, $msg) = @_;

    for my $f (qw/script_abs env cwd sock_path spawn_id notify_to/) {
        unless (defined $payload->{$f}) {
            warn "PreloadService::spawn_script: missing '$f' in payload; ignoring\n";
            return;
        }
    }

    my $child_a = fork;
    unless (defined $child_a) {
        warn "PreloadService::spawn_script: outer fork failed: $!\n";
        return;
    }
    if ($child_a) {
        waitpid $child_a, 0;
        return;
    }

    my $child_b = fork;
    if (!defined $child_b) {
        warn "PreloadService::spawn_script: inner fork failed: $!\n";
        POSIX::_exit(127);
    }
    if ($child_b) {
        POSIX::_exit(0);
    }

    require Long::Jump;
    Long::Jump::longjump('preload_spawn', {
        kind       => 'spawn_script',
        script_abs => $payload->{script_abs},
        argv       => $payload->{argv} // [],
        env        => $payload->{env}  // {},
        cwd        => $payload->{cwd},
        sock_path  => $payload->{sock_path},
        spawn_id   => $payload->{spawn_id},
        notify_to  => $payload->{notify_to},
    });

    print STDERR "PreloadService::spawn_script: longjump returned (anchor missing?)\n";
    POSIX::_exit(255);
}

# Runs in the grandchild (post-longjump) after the setjump frame has
# unwound PreloadService::run. Connects to the CLI's SCM_RIGHTS socket,
# receives stdin/stdout/stderr FDs, dup2s them, chdirs, swaps %ENV,
# notifies the harness of our pid, then runs the script via do().
sub _post_jump_spawn_script {
    my ($self, $payload) = @_;

    require POSIX;
    require IO::Socket::UNIX;
    require App::Yath2::Spawn::FdPass;

    _spawn_script_install_fds($payload);

    chdir $payload->{cwd} or POSIX::_exit(126);
    %ENV = %{$payload->{env}};

    $self->_spawn_script_notify_harness($payload);

    local @ARGV = @{$payload->{argv} // []};
    $0 = $payload->{script_abs};

    POSIX::_exit(_spawn_script_run($payload->{script_abs}));
}

sub _spawn_script_install_fds {
    my ($payload) = @_;

    my $sock = IO::Socket::UNIX->new(
        Peer => $payload->{sock_path},
        Type => IO::Socket::UNIX::SOCK_STREAM(),
    );
    unless ($sock) {
        print STDERR "yath spawn grandchild: connect $payload->{sock_path}: $!\n";
        POSIX::_exit(126);
    }

    my $fds;
    my $ok = eval { $fds = App::Yath2::Spawn::FdPass::recv_fds($sock, 3); 1 };
    unless ($ok && $fds && @$fds == 3) {
        print STDERR "yath spawn grandchild: recv_fds failed: $@\n";
        POSIX::_exit(126);
    }
    close $sock;

    POSIX::dup2($fds->[0], 0) or POSIX::_exit(126);
    POSIX::dup2($fds->[1], 1) or POSIX::_exit(126);
    POSIX::dup2($fds->[2], 2) or POSIX::_exit(126);
    POSIX::close($_) for @$fds;
}

# The inherited IPC client has pid_check() bound to the PreloadService
# PID and would croak in the grandchild; open a fresh listen=0
# connection for a single send_message instead.
sub _spawn_script_notify_harness {
    my ($self, $payload) = @_;

    require IPC::Manager;
    my $gc_client = IPC::Manager->connect(
        "spawn-gc-$$",
        $self->{+IPCM_INFO},
        listen => 0,
    );
    my $ok = eval {
        $gc_client->send_message($payload->{notify_to}, {
            kind     => 'script_spawned',
            pid      => $$,
            spawn_id => $payload->{spawn_id},
        });
        1;
    };
    return if $ok;

    print STDERR "yath spawn grandchild: script_spawned failed: $@\n";
    POSIX::_exit(126);
}

# Runtime die() is observable (eval returns undef + $@) and read
# failures show up via do() returning undef with $! set. Compile
# errors leave $@ set without making do() die, and a script may
# contain its own eval{die} that leaves $@ set on success — so
# "compile failed" cannot be distinguished from "ran fine with an
# internal eval" by inspecting $@ post-do. Scripts that need a
# non-zero exit for compile failure must wrap or exit() themselves.
sub _spawn_script_run {
    my ($script_abs) = @_;

    my ($rv, $do_io_err);
    my $did = eval {
        local $!;
        $rv        = do $script_abs;
        $do_io_err = $!;
        1;
    };
    my $eval_err = $@;

    if (!$did) {
        print STDERR "yath spawn: $eval_err\n";
        return 1;
    }
    if (!defined($rv) && $do_io_err) {
        print STDERR "yath spawn: cannot read $script_abs: $do_io_err\n";
        return 2;
    }
    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::PreloadService - Long-lived service that pre-loads
modules for a Resource::Preload.

=head1 STATUS

Skeleton. The service composes
L<Test2::Harness2::Role::Service> and
L<Test2::Harness2::Role::ResourceService>, accepts the preload identity
construction parameters that
L<Test2::Harness2::Resource::Preload/services> hands it
(C<name>, C<modules>, C<scope>, C<run_id>, C<is_role_consumer>), and
exposes them through C<service_started_fields>. The C<BEGIN> +
C<do_preload> + spawn-test plumbing lands in later tasks of the
preload-rework plan.

=head1 METHODS

=head2 init

Object::HashBase initializer. Validates required attributes
(C<preload_name>, C<modules>), applies defaults for C<scope>,
C<is_role_consumer>, C<kill_timeout>, C<state>, C<watch_pids>, and
C<own_pgroup>, derives C<workdir> from C<log_path>, and caches the
bus-level service name via L</_compute_name>.

=head2 name

Returns the bus-level service name (C<preload-NAME> for global scope,
C<preload-RUNID-NAME> for run scope).

=head2 _compute_name

Private. Derives the bus-level service name from C<preload_name>,
C<scope>, and C<run_id>.

=head2 service_started_fields

Extra fields emitted on the C<service_started> event so a log reader
can tell which preload this is and whether it is a Role::Preload
consumer.

=head2 hard_stop_pids

Returns the pids of any in-flight spawn workers that must be reaped
during a hard stop. Currently a stub returning an empty list.

=head2 emit_service_event

No-op placeholder; real JSONL emission lands with the spawn-pathway
task.

=head2 _role_consumer_class

Private. Returns the consumer class name when this preload was built
from a L<Test2::Harness2::Role::Preload> consumer, otherwise C<undef>.

=head2 do_preload

Sequentially C<require>s each module in C<modules>. For Role::Preload
consumers, loads the consumer class and delegates to its
C<do_preload>. Croaks with a clear message naming the preload and
failing module on error.

=head2 _fire_role_hook

Private. Fires a L<Test2::Harness2::Role::Preload> lifecycle hook on
the consumer class (if any). Exceptions warn but do not propagate.

=head2 _require_module

Private. Thin wrapper around C<require> that uses
L<Test2::Harness2::Util/mod2file>.

=head2 service_on_start

Called by Role::Service after the pgroup / subreaper /
C<service_started> steps. Adds the parent pid to C<watch_pids>, runs
L</do_preload>, instantiates the reloader, and sends C<preload_ready>
to the harness.

=head2 _instantiate_reloader

Private. Builds a reloader instance from C<reloader_class> +
C<reloader_args>. Failure is non-fatal (preload still works without
hot reload).

=head2 run_on_interval

Per-tick callback from IPC::Manager. Drives the reloader's
C<do_reload> and emits C<preload_broken> / C<preload_ready> on edge
transitions only.

=head2 _send_preload_state

Private. Sends a preload-state message (C<preload_broken>,
C<preload_ready>, etc.) to the harness with the standard
preload_name/scope/run_id identification.

=head2 restartable

Returns true. Preloads are stateless and replaceable; the harness's
restart-spiral cap in
L<Test2::Harness2::Role::ResourceServiceHost> handles permanent
failure.

=head2 run_returns_to_caller

Returns true. Tells L<IPC::Manager::Service::State> to return rather
than exit when L</run> returns, so the boot perl's C<-e> snippet can
resume parsing under the source filter installed by L</run>.

=head2 run_should_end

Returns true once C<state> is C<terminating>. Drives loop exit after
a Role::Service C<terminate> request.

=head2 run

Overrides L<Test2::Harness2::Role::Service/run> to install a
L<Long::Jump> C<preload_spawn> setjump anchor around the IPC loop.
Dispatches the post-longjump payload by kind (C<spawn_test>,
C<spawn_service>, C<spawn_script>) and, for C<spawn_test>, hands the
test path to L<goto::file> so the surviving perl continues as if it
had been invoked with the test file directly.

=head2 run_on_general_message

Async dispatch entry point for harness messages. Routes by C<kind>
to L</request_handler_spawn_test>, L</request_handler_spawn_service>,
or L</request_handler_spawn_script>.

=head2 request_handler_spawn_test

IPC handler for C<spawn_test>. Fires the C<pre_fork> role hook and
delegates to L</_collector_spawn_test>. See the source for the full
nine-step launch sequence (harness -> Collector -> grandchild ->
longjump -> goto::file -> test runs in C<main>).

=head2 _collector_spawn_test

Private. Calls L<Test2::Harness2::Collector/spawn> with a
C<launch_callback> (L</_test_grandchild_launch>) and an optional
C<post_fork_callback> for role consumers.

=head2 _test_grandchild_launch

Private. Test-grandchild body invoked from the Collector's
C<launch_callback>. Applies env, resets process and Test2 state
(L</_reset_process_state>, L</_reset_test2_state>), pre-loads
L<Test2::Formatter::Stream2>, fires the C<pre_launch> role hook,
then longjumps C<preload_spawn> with the test path.

=head2 _reset_process_state

Private. Clears C<@ARGV>, reseeds C<srand>, and reinitializes
L<FindBin> and L<Getopt::Long>.

=head2 _reset_test2_state

Private. Calls C<test2_post_preload_reset>, clears the hub stack,
and zeroes the lingering C<exit_callbacks>, C<post_load_callbacks>,
context callbacks, and C<formatter> on the cached C<$Test2::API::INST>.

=head2 request_handler_spawn_service

IPC handler for C<spawn_service>. Validates payload, double-forks to
orphan the grandchild off this preload, then longjumps
C<preload_spawn> with C<kind=spawn_service>. The grandchild resumes
in L</_post_jump_spawn_service>.

=head2 request_handler_reload

Synchronous handler for C<reload>. Drives one tick of the configured
reloader (no-op success if no reloader is configured) and returns
C<< {ok => 1} >> or C<< {ok => 0, error => ...} >>.

=head2 _post_jump_spawn_service

Private. Grandchild post-longjump body for C<spawn_service>. Loads
the resource service class, constructs it under a fresh IPC peer
name, materializes the client, sends C<resource_service_started> to
the harness, and enters the new service's run loop.

=head2 request_handler_spawn_script

IPC handler for C<spawn_script>. Validates payload, double-forks,
then longjumps C<preload_spawn> with C<kind=spawn_script>. The
grandchild resumes in L</_post_jump_spawn_script>.

=head2 _post_jump_spawn_script

Private. Grandchild post-longjump body for C<spawn_script>.
Installs CLI-passed FDs via L</_spawn_script_install_fds>, chdirs,
swaps C<%ENV>, notifies the harness via
L</_spawn_script_notify_harness>, then runs the script via
L</_spawn_script_run>.

=head2 _spawn_script_install_fds

Private. Connects to the CLI's SCM_RIGHTS socket, receives three FDs
via L<App::Yath2::Spawn::FdPass>, and C<dup2>s them over
STDIN/STDOUT/STDERR.

=head2 _spawn_script_notify_harness

Private. Opens a fresh non-listening IPC client (the inherited one's
C<pid_check> is bound to the parent pid) and sends C<script_spawned>
to the harness.

=head2 _spawn_script_run

Private. Runs the script via C<do $script_abs>, distinguishing
runtime C<die>, missing-file, and clean exits. Returns the intended
process exit code.

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
