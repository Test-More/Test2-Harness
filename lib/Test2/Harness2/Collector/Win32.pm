package Test2::Harness2::Collector::Win32;
use strict;
use warnings;

our $VERSION = '2.000011';

# All methods in this file are installed into the
# Test2::Harness2::Collector class namespace below. The file itself
# exists only to keep the Win32-specific code paths out of the
# unix-side reader's view; nothing constructs a
# Test2::Harness2::Collector::Win32 directly.
#
# Loaded only on Windows (see the `require ... if IS_WIN32` line in
# Test2::Harness2::Collector). On unix the methods below are absent
# and the dispatchers in Collector.pm never call them.

use Carp qw/croak/;
use POSIX ();
use Scope::Guard ();
use Scalar::Util qw/blessed/;

use Test2::Harness2::Util::JSON ();
use Test2::Harness2::Collector::Util ();

package    # hide from PAUSE indexer; we are extending Test2::Harness2::Collector
    Test2::Harness2::Collector;

# Windows has no fork. Serialize the collector's constructor args to a
# temp JSON file, then spawn a fresh perl that loads this module and
# calls collect_from_file($json) -- same pattern as the legacy
# start_collected_process. Open file handles cannot cross the
# system(1, ...) boundary, so handle-based collection is rejected.
sub _spawn_collector_win32 {
    my $self = shift;

    croak "Handle-based collection is not supported on Windows; use 'launch' instead"
        unless defined $self->{+LAUNCH};

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

    my $json_file = Test2::Harness2::Util::JSON::encode_json_file(\%params);

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

# system(1, @cmd) on Win32 is _spawnvp(P_NOWAIT, ...) which returns the
# pseudo-process ID (a positive integer) on success, or -1 on failure.
# This is NOT the exit code -- it is the PID to pass to waitpid().
# Isolated in its own method so tests can override it without patching
# CORE::GLOBAL::system (which does not intercept already-compiled opcodes).
sub _win32_spawn {
    my $self = shift;
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
    require Test2::Harness2::Util::IPC;
    Test2::Harness2::Util::IPC::swap_io(\*STDOUT, $out_w->wh);
    Test2::Harness2::Util::IPC::swap_io(\*STDERR, $err_w->wh);
    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    # Baseline for child_times/child_wall. See _launch_child_unix.
    $self->{+_CHILD_FORK_TIMES} = [times()];
    $self->{+_CHILD_FORK_STAMP} = time;

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
    my $cmdline = join(' ', map { Test2::Harness2::Collector::Util::win32_quote_arg($_) } @$cmd);

    my %env = $self->_child_env_overrides;

    # Merge overrides into the current environment for the spawn call.
    # Win32::Job->spawn inherits the parent environment; we simulate
    # local-env by temporarily setting the vars before spawning.
    local @ENV{keys %env} = values %env;

    # Baseline for child_times/child_wall. See _launch_child_unix.
    $self->{+_CHILD_FORK_TIMES} = [times()];
    $self->{+_CHILD_FORK_STAMP} = time;

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
    # assigned to it -- matching the Unix kill(0 - $pgid) semantics.
    $self->{+_WIN32_JOB} = $job;

    return $pid;
}

# Backwards-compat method shim: legacy callers (and the unit tests
# under t/AI/unit/Collector/) reference $self->_win32_quote_arg(...).
# Forwards to the pure helper in Test2::Harness2::Collector::Util.
sub _win32_quote_arg {
    my $self = shift;
    return Test2::Harness2::Collector::Util::win32_quote_arg(@_);
}

# Windows perl does not have a useful SIGTERM; use SIGINT as the
# graceful-shutdown signal there. No TERM/KILL escalation -- the
# pid_is_running check before this method already confirmed the
# target is alive, and waitpid blocks until the kill takes effect.
sub _kill_child_win32 {
    my $self = shift;
    my ($pid) = @_;

    kill('INT', $pid);
    waitpid($pid, 0);
    return $?;
}

# Release the Win32::Job handle explicitly. When the last reference is
# dropped, Windows closes the job handle. Processes already assigned to
# the job are terminated only if the job was created with
# JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE -- Win32::Job sets this flag by
# default, so all descendants are reaped atomically.
sub DESTROY {
    my $self = shift;
    delete $self->{+_WIN32_JOB};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Win32 - Windows-specific code paths for the collector.

=head1 DESCRIPTION

Loaded by L<Test2::Harness2::Collector> only when running on
C<MSWin32>. Defines the win32 spawn / launch / kill / cleanup methods
inside the C<Test2::Harness2::Collector> class namespace so the
unix-side reader of C<Collector.pm> never has to skim past
platform-dead code.

This module has no public entry point. The methods it installs are
called by L<Test2::Harness2::Collector>'s platform-dispatch sites
(C<_spawn_collector>, C<_launch_child>, C<_kill_child>) which
delegate to C<_*_win32> when C<IS_WIN32> is true.

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
