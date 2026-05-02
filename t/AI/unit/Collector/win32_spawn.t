use Test2::V0;

# Unit tests for the Windows spawn paths in Test2::Harness2::Collector.
#
# These tests run cross-platform: the Windows spawn methods are ordinary Perl
# subs that can be exercised on any OS by providing a minimal blessed hash and
# mocking _win32_spawn() — the thin wrapper around `system 1, @cmd` — via a
# local *Test2::Harness2::Collector::_win32_spawn override.
#
# The Win32 methods now live in Test2::Harness2::Collector::Win32 and are
# loaded by Collector.pm only on MSWin32. Force-load them here so the
# methods are available on every platform.

use Test2::Harness2::Collector;
use Test2::Harness2::Collector::Win32;

# Smoke check: every method extracted into the Win32 module must be
# callable as a Test2::Harness2::Collector method after the module is
# loaded.
subtest 'Win32 module installs methods into Collector namespace' => sub {
    for my $m (qw{
        _spawn_collector_win32
        collect_from_file
        _win32_spawn
        _check_new_pgroup_supported_on_win32
        _launch_child_win32
        _launch_child_win32_job
        _win32_quote_arg
        _kill_child_win32
        DESTROY
    })
    {
        ok(Test2::Harness2::Collector->can($m), "Test2::Harness2::Collector->can('$m')");
    }
};

# ---------------------------------------------------------------------------
# Helper: build a minimal blessed Collector-like object with the attributes
# needed by the methods under test.  We bypass the full constructor (which
# requires a live ipcm/IPC stack) by blessing a plain hash.
# ---------------------------------------------------------------------------
sub fake_collector {
    my (%args) = @_;
    return bless {
        launch          => ['perl', '-e', '1'],
        new_pgroup      => 0,
        env_vars        => {},
        kill_timeout    => 15,
        parser          => undef,
        _loggers_spec   => [],
        _observers_spec => [],
        %args,
    }, 'Test2::Harness2::Collector';
}

# ---------------------------------------------------------------------------
# _check_new_pgroup_supported_on_win32
# ---------------------------------------------------------------------------
subtest '_check_new_pgroup_supported_on_win32 — no-op when new_pgroup is false' => sub {
    my $c = fake_collector(new_pgroup => 0);
    my $ok = eval { $c->_check_new_pgroup_supported_on_win32(); 1 };
    ok($ok, "does not croak when new_pgroup is false");
};

subtest '_check_new_pgroup_supported_on_win32 — croaks when Win32::Job absent and new_pgroup set' => sub {
    my $c = fake_collector(new_pgroup => 1);

    # Temporarily hide Win32::Job from %INC and block require from loading it
    # by injecting a stub override in the Collector's namespace.
    local %INC = %INC;
    delete $INC{'Win32/Job.pm'};

    # Shadow require so Win32::Job appears absent.
    no warnings 'once';
    local *CORE::GLOBAL::require = sub {
        my ($mod) = @_;
        die "Can't locate Win32/Job.pm in \@INC (mocked)\n"
            if $mod eq 'Win32::Job' || $mod eq 'Win32/Job.pm';
        return CORE::require($_[0]);
    };

    my $ok  = eval { $c->_check_new_pgroup_supported_on_win32(); 1 };
    my $err = $@;
    ok(!$ok, "croaks when Win32::Job is not installed");
    like($err, qr/Win32::Job/, "error message mentions Win32::Job");
    like($err, qr/new_pgroup/, "error message mentions new_pgroup");
};

subtest '_check_new_pgroup_supported_on_win32 — does not croak when Win32::Job is present' => sub {
    # Simulate Win32::Job being installed by injecting a stub into %INC.
    local %INC = %INC;
    $INC{'Win32/Job.pm'} = '/fake/path/Win32/Job.pm';

    # Also stub the package so ->new() would not die if somehow called.
    {
        no strict 'refs';
        *{'Win32::Job::new'} = sub { bless {}, 'Win32::Job' }
            unless defined &{'Win32::Job::new'};
    }

    my $c  = fake_collector(new_pgroup => 1);
    my $ok = eval { $c->_check_new_pgroup_supported_on_win32(); 1 };
    ok($ok, "does not croak when Win32::Job is available");
};

# ---------------------------------------------------------------------------
# _win32_quote_arg
# ---------------------------------------------------------------------------
subtest '_win32_quote_arg — plain argument passes through unchanged' => sub {
    my $c = fake_collector();
    is($c->_win32_quote_arg('perl'), 'perl', "no quoting needed");
};

subtest '_win32_quote_arg — argument with space is wrapped in double-quotes' => sub {
    my $c = fake_collector();
    is($c->_win32_quote_arg('Program Files'), '"Program Files"', "spaces quoted");
};

subtest '_win32_quote_arg — embedded double-quote is escaped' => sub {
    my $c = fake_collector();
    is($c->_win32_quote_arg('say "hi"'), '"say \"hi\""', "embedded quotes escaped");
};

# ---------------------------------------------------------------------------
# _spawn_collector_win32 — croak when _win32_spawn returns <= 0
#
# We mock _win32_spawn() so we never actually spawn a process.
# encode_json_file creates a real temp file; we verify the croak fires and
# (via the error message format) that the appropriate guard path triggered.
# ---------------------------------------------------------------------------
subtest '_spawn_collector_win32 — croaks when spawn returns 0' => sub {
    my $c = fake_collector();

    no warnings 'redefine';
    local *Test2::Harness2::Collector::_win32_spawn = sub { return 0 };

    my $ok  = eval { $c->_spawn_collector_win32(); 1 };
    my $err = $@;

    ok(!$ok,  "croaks when _win32_spawn returns 0");
    like($err, qr/spawn returned 0/, "error message reports the bad return value");
};

subtest '_spawn_collector_win32 — croaks when spawn returns -1' => sub {
    my $c = fake_collector();

    no warnings 'redefine';
    local *Test2::Harness2::Collector::_win32_spawn = sub { return -1 };

    my $ok  = eval { $c->_spawn_collector_win32(); 1 };
    my $err = $@;

    ok(!$ok,  "croaks when _win32_spawn returns -1");
    like($err, qr/spawn returned -1/, "error message reports the bad return value");
};

subtest '_spawn_collector_win32 — croaks when _win32_spawn dies' => sub {
    my $c = fake_collector();

    no warnings 'redefine';
    local *Test2::Harness2::Collector::_win32_spawn = sub { die "mock spawn death\n" };

    my $ok  = eval { $c->_spawn_collector_win32(); 1 };
    my $err = $@;

    ok(!$ok,  "croaks when _win32_spawn dies");
    like($err, qr/eval died/, "error message indicates eval death path");
};

# ---------------------------------------------------------------------------
# _launch_child_win32 — croak when _win32_spawn returns <= 0
#
# _launch_child_win32 calls swap_io() which redirects STDOUT/STDERR.  We use
# a subclass that overrides the method to skip handle redirection so tests do
# not interfere with the test process's own stdio.
# ---------------------------------------------------------------------------
{
    package T2H2Test::Collector::NoHandles;
    use parent -norequire, 'Test2::Harness2::Collector';
    use Carp qw/croak/;

    # Re-implement _launch_child_win32 with the same guard logic but without
    # the swap_io / open-restore calls so tests don't touch real file handles.
    sub _launch_child_win32 {
        my $self = shift;
        my ($out_r, $out_w, $err_r, $err_w, $orig_stdout, $orig_stderr) = @_;

        $self->_check_new_pgroup_supported_on_win32();

        my $cmd = $self->{launch};

        return $self->_launch_child_win32_job($cmd, $out_w, $err_w)
            if $self->{new_pgroup};

        # Skip real handle redirection in tests.
        my $pid;
        my $ok;
        {
            my %env = $self->_child_env_overrides;
            local @ENV{keys %env} = values %env;
            $ok = eval { $pid = $self->_win32_spawn(@$cmd); 1 };
        }
        my $err = $@;

        # Skip real STDOUT/STDERR restore in tests.

        croak "Failed to spawn '@$cmd' (eval died): $err"
            if !$ok;
        croak "Failed to spawn '@$cmd' (spawn returned ${\($pid // 'undef')}): $!"
            if !defined $pid || $pid <= 0;

        return $pid;
    }
}

sub fake_no_handles_collector {
    my (%args) = @_;
    return bless {
        launch          => ['perl', '-e', '1'],
        new_pgroup      => 0,
        env_vars        => {},
        kill_timeout    => 15,
        parser          => undef,
        _loggers_spec   => [],
        _observers_spec => [],
        %args,
    }, 'T2H2Test::Collector::NoHandles';
}

subtest '_launch_child_win32 — croaks when spawn returns 0' => sub {
    my $c = fake_no_handles_collector();

    no warnings 'redefine';
    local *Test2::Harness2::Collector::_win32_spawn = sub { return 0 };

    my $ok  = eval { $c->_launch_child_win32(undef, undef, undef, undef, undef, undef); 1 };
    my $err = $@;

    ok(!$ok,  "croaks when spawn returns 0");
    like($err, qr/spawn returned 0/, "error message reports the bad return value");
};

subtest '_launch_child_win32 — croaks when spawn returns -1' => sub {
    my $c = fake_no_handles_collector();

    no warnings 'redefine';
    local *Test2::Harness2::Collector::_win32_spawn = sub { return -1 };

    my $ok  = eval { $c->_launch_child_win32(undef, undef, undef, undef, undef, undef); 1 };
    my $err = $@;

    ok(!$ok,  "croaks when spawn returns -1");
    like($err, qr/spawn returned -1/, "error message reports the bad return value");
};

subtest '_launch_child_win32 — croaks when _win32_spawn dies' => sub {
    my $c = fake_no_handles_collector();

    no warnings 'redefine';
    local *Test2::Harness2::Collector::_win32_spawn = sub { die "mock spawn death\n" };

    my $ok  = eval { $c->_launch_child_win32(undef, undef, undef, undef, undef, undef); 1 };
    my $err = $@;

    ok(!$ok,  "croaks when _win32_spawn dies");
    like($err, qr/eval died/, "error message indicates eval death path");
};

# ---------------------------------------------------------------------------
# Win32::Job path — Windows-only live test
# ---------------------------------------------------------------------------
SKIP: {
    skip "Win32::Job live tests only run on MSWin32", 1
        unless $^O eq 'MSWin32';

    skip "Win32::Job not installed", 1
        unless eval { require Win32::Job; 1 };

    subtest 'Win32::Job path spawns child and assigns it to a job object' => sub {
        my $c = fake_collector(new_pgroup => 1);

        require Atomic::Pipe;
        my ($out_r, $out_w) = Atomic::Pipe->pair;
        my ($err_r, $err_w) = Atomic::Pipe->pair;

        my $orig_stdout = \*STDOUT;
        my $orig_stderr = \*STDERR;

        my $pid = eval {
            $c->_launch_child_win32($out_r, $out_w, $err_r, $err_w, $orig_stdout, $orig_stderr);
        };
        my $err = $@;

        ok(!$err,                        "no exception spawning with Win32::Job");
        ok(defined $pid && $pid > 0,     "returned a positive PID: $pid");
        ok($c->{_win32_job},             "job object stored on collector");

        # Releasing the collector should terminate the job.
        undef $c;
        select(undef, undef, undef, 0.1);    # brief wait for Windows cleanup
        ok(!kill(0, $pid), "child no longer running after job handle released");

        $_->close for ($out_r, $out_w, $err_r, $err_w);
    };
}

done_testing;
