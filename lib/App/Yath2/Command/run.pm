package App::Yath2::Command::run;
use strict;
use warnings;

our $VERSION = '2.000013';

use POSIX ();
use Time::HiRes qw/time/;

use Test2::Harness2::Spawn;
use Test2::Harness2::Util qw/mod2file tinysleep/;

use App::Yath2::TestFile;
use App::Yath2::Options::Renderer();
use App::Yath2::Renderer2::Spawn();
use App::Yath2::Util::IPC qw/discover_daemons assert_daemon_alive/;

use Role::Tiny::With;
with 'App::Yath2::Role::Command';

use Object::HashBase qw{
    <args
    <settings
};

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
    'App::Yath2::Options::Harness',
    'App::Yath2::Options::IPC',
    'App::Yath2::Options::Log',
    'App::Yath2::Options::Preload',
    'App::Yath2::Options::Reloader',
    'App::Yath2::Options::Renderer',
    'App::Yath2::Options::Resource',
    'App::Yath2::Options::Runner',
    'App::Yath2::Options::Tests',
);

option_group {group => 'run', category => "Run Options"} => sub {
    option workdir => (
        type           => 'Scalar',
        long_examples  => [' DIR'],
        short_examples => [' DIR'],
        description    => 'Workdir of an existing yath daemon (where its IPC info file lives). Without --workdir / --ipc-file, `yath run` auto-discovers a running daemon.',
    );

    option latest => (
        type        => 'Bool',
        default     => 0,
        description => 'When auto-discovery finds multiple running daemons, pick the most recently started one instead of erroring.',
    );
};

sub load_plugins   { 1 }
sub load_resources { 1 }
sub load_renderers { 0 }

sub accepts_dot_args   { 0 }
sub args_include_tests { 1 }

sub group { 'daemon' }

sub summary { "Run tests on a yath daemon started via `yath start`" }

sub description {
    return <<"    EOT";
Hand a list of test files to a running yath daemon (started with
`yath start`) and stream events back to the local renderer until the
run completes. Exits with the run's pass/fail aggregate.

The daemon is located automatically (this user's running daemons in
this project root). Pass --workdir DIR or --ipc-file PATH to target a
specific one, or --latest to pick the newest when multiple match.
    EOT
}

sub run {
    my $self = shift;

    local $| = 1;
    STDERR->autoflush(1);

    my $settings = $self->{+SETTINGS};
    my $args     = $self->{+ARGS} // [];

    die "No test files supplied.\nUsage: yath run [--workdir DIR | --ipc-file PATH] FILE-OR-DIR [...]\n"
        unless @$args;

    my $info = discover_daemons(
        settings => $settings,
        workdir  => $settings->run->workdir,
        latest   => $settings->run->latest,
    );
    my $ipc_path = $info->{_path};

    die "IPC info file '$ipc_path' is missing ipcm_info\n"
        unless $info->{ipcm_info};
    die "IPC info file '$ipc_path' is missing workdir\n"
        unless $info->{workdir};
    assert_daemon_alive($info);

    my $workdir = $info->{workdir};
    my $logdir  = "$workdir/logs";

    # Build a Spawn handle that points at the running daemon. The
    # daemon was spawned with watch_pids => [] by `yath start`, so
    # nothing we do here can take it down on accident -- but pin
    # terminate_on_destroy off explicitly anyway in case we evolve
    # the protocol.
    my $spawn = Test2::Harness2::Spawn->new(
        pid                  => $info->{pid},
        ipcm_info            => $info->{ipcm_info},
        workdir              => $workdir,
        terminate_on_destroy => 0,
    );

    my @files = $self->_collect_test_files($args);

    my $run_id = $self->_queue_run($spawn, \@files);

    eval { $spawn->subscribe(global => 1, run => $run_id, state => 1); 1 }
        or warn "subscribe failed: $@";

    # Fork one renderer child per active renderer. Each child drives
    # one renderer instance via App::Yath2::Renderer2::Loop against
    # the daemon's live log dir. When this `yath run` exits the
    # parent's PID disappears -- the renderer loop sees that via its
    # PID-watch shutdown layer and drains.
    my $renderer_pids = $self->_spawn_renderers($logdir, $spawn);

    my ($ipc_pass) = $self->_drive_ipc_loop($spawn, $run_id, $renderer_pids);

    eval { $spawn->unsubscribe; 1 } or warn "unsubscribe failed: $@";

    # Reap renderer children. The daemon (parent_pid) and yath run
    # (command_pid) both stay alive across the renderer's loop, so
    # neither PID-watch nor LIVE-removal triggers a drain on their
    # own -- signal SIGTERM so the renderer process exits and yath
    # run can return its result without leaving the renderer
    # parked on FileMonitor->await_change.
    my $renderer_exit = App::Yath2::Renderer2::Spawn::reap_renderers(
        pids         => $renderer_pids,
        signal_first => 1,
    );
    my $log_pass = $renderer_exit == 0;

    return ($ipc_pass && $log_pass) ? 0 : 1;
}

sub _collect_test_files {
    my ($self, $args) = @_;
    my @files;
    for my $arg (@$args) {
        if (-d $arg) {
            require File::Find;
            File::Find::find(
                {
                    no_chdir => 1,
                    wanted   => sub {
                        return unless -f $_ && -r _;
                        return unless /\.(?:t|t2)\z/;
                        no strict 'refs';
                        push @files => App::Yath2::TestFile->new(file => ${'File::Find::name'});
                    },
                },
                $arg,
            );
            next;
        }
        die "Not a readable test file or directory: $arg\n" unless -f $arg && -r _;
        push @files => App::Yath2::TestFile->new(file => $arg);
    }
    die "No test files matched under: @$args\n" unless @files;
    return @files;
}

sub _queue_run {
    my ($self, $spawn, $files) = @_;
    my $settings = $self->{+SETTINGS};

    my %args = (files => $files);
    if (my $hash_seed = $settings->tests->set_hash_seed) {
        $args{hash_seed} = $hash_seed if length $hash_seed;
    }
    if (my $chdir = $settings->tests->chdir) {
        $args{chdir} = $chdir if length $chdir;
    }

    # Per-run resources travel as a serializable recipe:
    #   [ [ class, key => value, ... ], ... ]
    # The harness rehydrates each entry with $class->new(@args). See
    # Test2::Harness2::request_handler_queue_test_run.
    my @resource_specs = $self->_build_resource_specs;
    $args{resources} = \@resource_specs if @resource_specs;

    my $queued = $spawn->queue_test_run(%args);
    die "queue_test_run failed: " . ($queued->{error} // '(no error)') . "\n"
        unless $queued->{ok};

    return $queued->{run_id};
}

# Build the per-run resource recipe shipped to the daemon. Per-run
# resources are additive on top of the daemon's globals; the daemon
# already owns whichever CPU/Memory/Throttle/JobCount/etc. stack the
# operator picked at `yath start` time, so re-shipping any of those
# from here would just install redundant duplicate gates bound to
# this single Run.
#
# Currently the only resource shape that genuinely belongs per-run
# is Resource::Preload with scope='run'; ship those and nothing else.
sub _build_resource_specs {
    my $self = shift;

    require App::Yath2::Preload;
    my @out;
    for my $args (App::Yath2::Preload::preload_resource_args(settings => $self->{+SETTINGS}, scope => 'run')) {
        push @out => ['Test2::Harness2::Resource::Preload', %$args];
    }

    return @out;
}

sub _spawn_renderers {
    my ($self, $logdir, $spawn) = @_;
    my $settings    = $self->{+SETTINGS};
    my $harness_pid = $spawn->pid;

    my $specs = App::Yath2::Options::Renderer->renderer_specs($settings);
    return [] unless @$specs;

    return App::Yath2::Renderer2::Spawn::spawn_renderers(
        logdir      => $logdir,
        settings    => $settings,
        specs       => $specs,
        parent_pid  => $harness_pid,
        command_pid => $$,
        spawn       => $spawn,
        live        => 1,
    );
}

# Same flow as App::Yath2::Command::test::_drive_ipc_loop -- watch
# state broadcasts for pass/fail signals, plus poll run_results so a
# run that completed before our subscribe took effect still resolves.
sub _drive_ipc_loop {
    my ($self, $spawn, $run_id, $renderer_pids) = @_;

    my $state = {
        ipc_pass     => 1,
        seen_run_end => 0,
        harness_pid  => $spawn->pid,
        ipc          => $spawn->handle,
        next_poll    => 0,
    };

    while (1) {
        my $renderer_gone = App::Yath2::Renderer2::Spawn::renderers_all_reaped(pids => $renderer_pids);

        eval { $state->{ipc}->poll(0); 1 } or warn "ipc poll: $@";
        $self->_drain_state_messages($state);
        $self->_poll_run_results($state, $spawn, $run_id);

        last if $state->{seen_run_end};

        # Daemon died mid-run: bail with failure. We never saw an
        # end-of-run signal, so pass/fail is unknowable -- treat as
        # failure rather than silently returning success.
        if ($state->{harness_pid} && !kill(0 => $state->{harness_pid})) {
            warn "yath run: harness pid $state->{harness_pid} disappeared before the run completed.\n";
            $state->{ipc_pass} = 0;
            last;
        }

        if ($renderer_gone) {
            $self->_finalize_after_renderer_exit($state, $spawn, $run_id);
            last;
        }

        tinysleep(0.05);
    }

    return $state->{ipc_pass};
}

sub _drain_state_messages {
    my ($self, $state) = @_;

    for my $msg ($state->{ipc}->messages) {
        my $content = $msg->content;
        next unless ref($content) eq 'HASH';
        next unless ($content->{type} // '') eq 'state'
                 && ($content->{item} // '') eq 'run';

        my $rd = $content->{state};
        next unless ref($rd) eq 'HASH';

        if (defined $rd->{pass}) {
            $state->{ipc_pass} = 0 unless $rd->{pass};
        }
        else {
            my $results = ref($rd->{results}) eq 'HASH' ? $rd->{results} : {};
            for my $jid (keys %$results) {
                my $jr = $results->{$jid};
                next unless ref($jr) eq 'HASH';
                next unless defined $jr->{completed_at};
                $state->{ipc_pass} = 0 unless $jr->{pass};
            }
        }

        my $pen = ref($rd->{pending}) eq 'ARRAY' ? scalar @{$rd->{pending}} : 1;
        my $run = ref($rd->{running}) eq 'ARRAY' ? scalar @{$rd->{running}} : 1;
        my $have_results = ref($rd->{results}) eq 'HASH' && %{$rd->{results}};
        $state->{seen_run_end} = 1 if $pen == 0 && $run == 0 && $have_results;
    }
}

# Fall-back: poll run_results twice a second. The harness records every
# completed run in COMPLETED_RUNS at terminal time, so a run that
# finished before our subscribe took effect (small, fast tests) still
# surfaces here.
sub _poll_run_results {
    my ($self, $state, $spawn, $run_id) = @_;
    return if time < $state->{next_poll};

    $state->{next_poll} = time + 0.5;
    my $res = eval { $spawn->run_results($run_id); };
    return unless ref($res) eq 'HASH' && $res->{ok};

    my $rstate = $res->{state} // '';
    return unless $rstate ne 'running' && exists $res->{pass};

    $state->{ipc_pass}     = 0 unless $res->{pass};
    $state->{seen_run_end} = 1;
}

# Renderer exiting first only means the on-disk log signalled end-of-run;
# the IPC state broadcast may still be in flight. Take one authoritative
# run_results poll so pass/fail does not silently default to 1.
sub _finalize_after_renderer_exit {
    my ($self, $state, $spawn, $run_id) = @_;

    my $res = eval { $spawn->run_results($run_id); };
    if (ref($res) eq 'HASH' && $res->{ok} && exists $res->{pass}) {
        $state->{ipc_pass} = 0 unless $res->{pass};
        return;
    }

    # No authoritative pass/fail answer (request errored or returned
    # nothing). Most commonly the daemon went away mid-run before
    # writing the terminal snapshot -- either way fail closed.
    warn "yath run: run_results did not return a pass/fail; treating as failure.\n";
    $state->{ipc_pass} = 0;
}

1;

__END__

=head1 METHODS

=head2 _collect_test_files

Walk the positional arguments, expanding directories with L<File::Find> for
C<.t> / C<.t2> files and wrapping each match in an L<App::Yath2::TestFile>.

=head2 _queue_run

Submit the collected test files to the daemon via
L<Test2::Harness2::Spawn/queue_test_run>, including any per-run resource
recipe, and return the assigned run_id.

=head2 _build_resource_specs

Build the serializable per-run resource recipe. Only Resource::Preload entries
with C<scope='run'> are shipped; global resources are owned by the daemon.

=head2 _spawn_renderers

Resolve the active renderer set via
L<App::Yath2::Options::Renderer/renderer_specs> and fork one
L<App::Yath2::Renderer2::Loop> child per spec against the daemon's live
log dir. Returns an arrayref of child pids.

=head2 _drive_ipc_loop

Main client loop: poll the IPC bus, drain state broadcasts, fall back to
C<run_results> polling, and watch for the daemon or renderer disappearing
before end-of-run. Returns the IPC-side pass/fail bit.

=head2 _drain_state_messages

Pull pending bus messages and update C<ipc_pass> and C<seen_run_end> from
run-state broadcasts.

=head2 _poll_run_results

Twice-a-second authoritative poll for runs that completed before our
subscription took effect; sets C<seen_run_end> + C<ipc_pass> from
L<Test2::Harness2::Spawn/run_results>.

=head2 _finalize_after_renderer_exit

When the renderer exits first, take one final C<run_results> poll so pass/fail
never silently defaults to success.

=head1 POD IS AUTO-GENERATED

=cut
