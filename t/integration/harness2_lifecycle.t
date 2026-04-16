use Test2::V0;
use File::Temp qw/tempdir/;
use POSIX qw/:sys_wait_h/;

use Test2::Harness2;

sub wait_until {
    my ($check, $timeout_sec) = @_;
    my $deadline = time + $timeout_sec;
    while (time < $deadline) {
        return 1 if $check->();
        select undef, undef, undef, 0.05;
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

    my $spawn = Test2::Harness2->spawn(workdir => $dir);
    my $q     = $spawn->queue_test_run(files => [$tf]);
    ok($q->{ok}, 'queued');

    # Wait for status to show a running job.
    my $running_pid;
    wait_until(
        sub {
            my $s = $spawn->status;
            $running_pid = $s->{running} && $s->{running}{pid};
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

    my $spawn = Test2::Harness2->spawn(workdir => $dir);
    $spawn->queue_test_run(files => [$tf]);

    # Wait for the run to complete (the test dies, the collector finishes).
    wait_until(
        sub {
            my $s = $spawn->status;
            return !$s->{running} && !@{$s->{queue}};
        },
        15
    ) or diag "run did not complete";

    ok(kill(0, $spawn->pid), 'harness still alive after test signalled its own pgroup');

    $spawn->finish;
    $spawn->wait;
};

done_testing;
