use Test2::V0;
use File::Temp qw/tempdir/;
use POSIX qw/:sys_wait_h _exit/;
use Time::HiRes qw/sleep/;

use lib 't/lib';
use Test2::Harness2::TestFile;
use Test2::Harness2::Test::Loggers qw/classic_harness_loggers classic_test_loggers/;

use Test2::Harness2;

sub wait_until {
    my ($check, $timeout_sec) = @_;
    my $deadline = time + $timeout_sec;
    while (time < $deadline) {
        return 1 if $check->();
        sleep(0.05);
    }
    return 0;
}

# `kill 0, $pid` returns true as long as the process table has an
# entry for $pid -- which includes zombies. When we kill a service
# whose parent is gone (detach case) and end up running under a
# container init that does not reap (e.g. GitHub Actions matrix jobs
# without tini), the dead-but-unreaped process sticks around forever
# and `!kill(0, $pid)` never becomes true. Treat a zombie as "gone
# enough" for the purposes of the lifecycle tests by peeking at
# /proc/$pid/status; fall back to plain `kill 0` off Linux.
sub proc_gone {
    my ($pid) = @_;
    return 1 unless kill 0, $pid;
    return 0 unless $^O eq 'linux';
    open(my $fh, '<', "/proc/$pid/status") or return 1;
    while (my $line = <$fh>) {
        return 1 if $line =~ /^State:\s*Z\b/;
        last if $line =~ /^State:/;
    }
    return 0;
}

subtest 'Terminate mid-run kills collector and test process' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # Test file that sleeps forever.
    my $tf = "$dir/sleep.t";
    open my $fh, '>', $tf or die;
    print $fh "use Test2::V0; ok(1); sleep 60; done_testing;\n";
    close $fh;

    my $spawn = Test2::Harness2->spawn(
        workdir      => $dir,
        kill_timeout => 2,
        loggers      => classic_harness_loggers($dir),
        test_loggers => classic_test_loggers(),
    );
    my $q     = $spawn->queue_test_run(files => [Test2::Harness2::TestFile->new(file => $tf)]);
    ok($q->{ok}, 'queued');

    # Wait for status to show a running job.
    my $running_pid;
    wait_until(
        sub {
            my $s = $spawn->status;
            my ($first) = @{$s->{running} // []};
            $running_pid = $first && $first->{pid};
            return $running_pid ? 1 : 0;
        },
        10
    ) or die "test never started";

    ok(kill(0, $running_pid), 'collector pid is alive pre-terminate');

    $spawn->terminate;

    # Brief wait in case the OS hasn't fully reaped yet.
    wait_until(sub { !kill(0, $running_pid) }, 5);

    ok(!kill(0, $running_pid), 'collector pid is dead post-terminate');
    ok(!kill(0, $spawn->pid),  'service pid is dead post-terminate');
};

subtest 'test that signals its own pgroup does not kill the harness' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $tf = "$dir/kill-self.t";
    open my $fh, '>', $tf or die;
    print $fh <<'PERL';
use Test2::V0;
ok(1, "pre-kill");
kill 'TERM', 0;  # signal own pgroup; must not reach harness
sleep 1;         # in case signal arrives async
fail("should be dead by now");
done_testing;
PERL
    close $fh;

    my $spawn = Test2::Harness2->spawn(
        workdir      => $dir,
        kill_timeout => 2,
        loggers      => classic_harness_loggers($dir),
        test_loggers => classic_test_loggers(),
    );
    $spawn->queue_test_run(files => [Test2::Harness2::TestFile->new(file => $tf)]);

    # Wait for the run to complete (the test dies, the collector finishes).
    wait_until(
        sub {
            my $s = $spawn->status;
            return !@{$s->{running} // []} && !@{$s->{queue}};
        },
        15
    ) or diag "run did not complete";

    ok(kill(0, $spawn->pid), 'harness still alive after test signalled its own pgroup');

    $spawn->finish;
    $spawn->wait;
};

subtest 'service dies when its caller dies (no detach)' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $tf = "$dir/sleep.t";
    open my $fh, '>', $tf or die;
    print $fh "use Test2::V0; ok(1); sleep 60; done_testing;\n";
    close $fh;

    # Fork a helper that spawns the service and then exits forcibly without
    # detaching. The service should notice its caller is gone and exit.
    my $helper = fork // die "fork: $!";
    if (!$helper) {
        my $spawn = Test2::Harness2->spawn(
            workdir      => $dir,
            kill_timeout => 2,
            loggers      => classic_harness_loggers($dir),
            test_loggers => classic_test_loggers(),
        );
        $spawn->queue_test_run(files => [Test2::Harness2::TestFile->new(file => $tf)]);
        # Intentionally NOT detached — leak via _exit so DESTROY doesn't fire.
        _exit(0);
    }
    waitpid $helper, 0;

    # The service should exit on its own. The shutdown cascades harness
    # -> run service -> test collectors, so the kill_timeout grace at
    # each layer can stack (two windows worst-case here). With
    # kill_timeout => 2 above, 15s leaves comfortable headroom.
    ok(
        wait_until(
            sub {
                return 0 unless -e "$dir/logs/services/harness/events.jsonl";
                open my $fh, '<', "$dir/logs/services/harness/events.jsonl" or return 0;
                local $/;
                my $content = <$fh>;
                return $content =~ /service_stopped/;
            },
            15
        ),
        'service logged service_stopped after caller died'
    );
};

subtest 'detached service survives caller death' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $tf = "$dir/quick.t";
    open my $fh, '>', $tf or die;
    print $fh "use Test2::V0; ok(1); done_testing;\n";
    close $fh;

    # Pass the service pid back through a pipe so the outer test can clean up.
    pipe(my $r, my $w) or die "pipe: $!";
    my $helper = fork // die "fork: $!";
    if (!$helper) {
        close $r;
        my $spawn = Test2::Harness2->spawn(
            workdir      => $dir,
            kill_timeout => 2,
            loggers      => classic_harness_loggers($dir),
            test_loggers => classic_test_loggers(),
        );
        $spawn->detach;
        print $w $spawn->pid, "\n";
        close $w;
        _exit(0);
    }
    close $w;
    my $svc_pid = <$r>;
    chomp $svc_pid;
    close $r;
    waitpid $helper, 0;

    sleep(0.5);
    ok(kill(0, $svc_pid), 'detached service still alive after caller died');

    # Clean up: send TERM directly since we have no Spawn handle.
    # Under a container init that does not reap zombies, the dead
    # service sticks around as a zombie and plain `kill 0` keeps
    # returning true; proc_gone() also accepts zombie state.
    kill 'TERM', $svc_pid;
    wait_until(sub { proc_gone($svc_pid) }, 10);
    ok(proc_gone($svc_pid), 'service reaped after TERM');
};

done_testing;
