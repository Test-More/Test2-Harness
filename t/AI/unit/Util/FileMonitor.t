use Test2::V0;
use File::Temp qw/tempfile tempdir/;
use Time::HiRes qw/sleep time/;

use Test2::Harness2::Util::FileMonitor;

my $CLASS = 'Test2::Harness2::Util::FileMonitor';

subtest 'constructor requires file' => sub {
    like(
        dies { $CLASS->new },
        qr/'file' is a required attribute/,
        'missing file croaks',
    );
};

subtest 'initial call reports change' => sub {
    my ($fh, $path) = tempfile(UNLINK => 1);
    print $fh "first\n";
    close $fh;

    my $m = $CLASS->new(file => $path);
    ok($m->changed, 'first changed() is truthy (initial state always reports change)');
    ok(!$m->changed, 'second changed() with no modification is false');
};

subtest 'modifying file makes changed truthy again' => sub {
    my ($fh, $path) = tempfile(UNLINK => 1);
    print $fh "first\n";
    close $fh;

    my $m = $CLASS->new(file => $path);
    ok($m->changed, 'initial reads truthy');
    ok(!$m->changed, 'no change yet');

    # Make sure mtime advances on filesystems with one-second mtime
    # resolution by sleeping a tick before rewriting.
    sleep(1.1);
    open my $w, '>', $path or die "open: $!";
    print $w "second\n";
    close $w;

    ok($m->changed, 'modification detected');
    ok(!$m->changed, 'follow-up no-change is false');
};

subtest 'await_change returns 0 on timeout' => sub {
    my ($fh, $path) = tempfile(UNLINK => 1);
    print $fh "static\n";
    close $fh;

    my $m = $CLASS->new(file => $path);
    # Initial state always reports change; consume it.
    ok($m->changed, 'initial change consumed');

    my $start = time();
    my $rv    = $m->await_change(0.2);
    my $dur   = time() - $start;

    is($rv, 0, 'await_change returns 0 on timeout');
    ok($dur >= 0.15, 'await_change actually waited (>= ~150ms)');
};

subtest 'await_change returns delegate / 1 on change' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/file";
    open my $w, '>', $path or die $!;
    print $w "init\n";
    close $w;

    my $m = $CLASS->new(file => $path);
    ok($m->changed, 'consume initial change');

    # Schedule an out-of-band write via a forked child so await_change
    # returns from a real change rather than the initial state.
    my $pid = fork // die "Could not fork: $!";
    if ($pid == 0) {
        sleep(0.2);
        open my $cw, '>>', $path or die "open: $!";
        print $cw "more\n";
        close $cw;
        exit 0;
    }

    my $rv = $m->await_change(5.0);
    waitpid($pid, 0);

    is($rv, 1, 'await_change returns 1 (no delegate)');
};

subtest 'delegate accessor + propagation' => sub {
    my ($fh, $path) = tempfile(UNLINK => 1);
    print $fh "x\n";
    close $fh;

    my $delegate = bless {marker => 'D'}, 'Test2::Harness2::Util::FileMonitor::DelegateMock';

    my $m = $CLASS->new(file => $path, delegate => $delegate);
    is($m->delegate, $delegate, 'delegate() returns the supplied object');

    my $rv = $m->changed;
    is($rv, $delegate, 'changed returns the delegate on a real change');
    is($rv->{marker}, 'D', 'delegate object propagated, not a copy');
};

subtest 'no delegate returns 1' => sub {
    my ($fh, $path) = tempfile(UNLINK => 1);
    print $fh "y\n";
    close $fh;

    my $m = $CLASS->new(file => $path);
    is($m->changed, 1, 'changed returns 1 when no delegate is set');
};

subtest 'peek_changed does not consume the change signal' => sub {
    my ($fh, $path) = tempfile(UNLINK => 1);
    print $fh "x\n";
    close $fh;

    my $m = $CLASS->new(file => $path);

    is($m->peek_changed, 1, 'first peek reports change');
    is($m->peek_changed, 1, 'second peek still reports change (no ack)');
    is($m->changed,      1, 'changed reports change and consumes');
    is($m->peek_changed, 0, 'peek after consume returns 0');
    is($m->changed,      0, 'changed after consume returns 0');
};

subtest 'peek_changed propagates the delegate' => sub {
    my ($fh, $path) = tempfile(UNLINK => 1);
    print $fh "x\n";
    close $fh;

    my $delegate = bless {}, 'Test2::Harness2::Util::FileMonitor::DelegateMock';
    my $m = $CLASS->new(file => $path, delegate => $delegate);

    is($m->peek_changed, $delegate, 'peek returns delegate on truthy');
};

subtest 'sub-second sleeps use tinysleep, never raw sleep or 4-arg select' => sub {
    # Busy-loop polls in FileMonitor must use tinysleep so signals
    # (SIGCHLD / SIGTERM) interrupt the wait promptly. Time::HiRes::sleep
    # silently retries on EINTR, which would swallow the signal. Direct
    # 4-arg select is also banned; tinysleep wraps it.
    require Test2::Harness2::Util::FileMonitor;
    my $file = $INC{'Test2/Harness2/Util/FileMonitor.pm'};
    open(my $rh, '<', $file) or die "open '$file': $!";
    my $src = do { local $/; <$rh> };
    close $rh;

    unlike(
        $src,
        qr/select\s*\(\s*undef\s*,\s*undef\s*,\s*undef\b/,
        'no direct four-arg select() in FileMonitor source',
    );
    unlike(
        $src,
        qr/(?<![:_a-z])sleep\s*\(/i,
        'no bare sleep() / Time::HiRes::sleep call in FileMonitor source',
    );
    like(
        $src,
        qr/\btinysleep\s*\(/,
        'FileMonitor calls tinysleep()',
    );
};

done_testing;
