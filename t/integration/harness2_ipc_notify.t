use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/time sleep/;

use lib 't/lib';
use Test2::Harness2::TestFile;

use Test2::Harness2;

# ---------------------------------------------------------------------------
# Sanity-check that the IPC completion notification path is functional by
# verifying that 5 trivially-fast tests complete in a reasonable wall time.
#
# We don't over-constrain the timing (machines vary widely), but a run that
# takes longer than 20 seconds for 5 one-liner tests is clearly broken.
# The notification path means the service wakes immediately on each test
# finishing rather than waiting for the 0.2 s poll interval, so in practice
# this completes in well under 2 seconds on any modern machine.
# ---------------------------------------------------------------------------

sub wait_until {
    my ($check, $timeout_sec) = @_;
    my $deadline = time + $timeout_sec;
    while (time < $deadline) {
        return 1 if $check->();
        sleep(0.05);
    }
    return 0;
}

subtest 'five fast tests complete quickly via IPC notification' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # Create 5 trivially-fast test files.
    my @files;
    for my $i (1 .. 5) {
        my $tf = "$dir/fast_${i}.t";
        open my $fh, '>', $tf or die "open $tf: $!";
        print $fh "use Test2::V0; ok(1, 'test $i'); done_testing;\n";
        close $fh;
        push @files => $tf;
    }

    my $spawn = Test2::Harness2->spawn(workdir => $dir);
    isa_ok($spawn, ['Test2::Harness2::Spawn'], 'got a Spawn handle');
    ok(kill(0, $spawn->pid), 'service is alive before queuing');

    my @tfs = map { Test2::Harness2::TestFile->new(file => $_) } @files;
    my $queued = $spawn->queue_test_run(files => \@tfs);
    ok($queued->{ok}, 'queued 5-file run') or diag explain $queued;

    my $start = time;

    my $done = wait_until(
        sub {
            my $s = $spawn->status;
            return !@{$s->{running} // []} && !@{$s->{queue}};
        },
        20,
    );

    my $elapsed = time - $start;

    ok($done, "all 5 tests completed within 20s (took ${elapsed}s)");
    note "Wall time for 5 trivial tests: ${elapsed}s";

    # Loose upper-bound: if it took more than 10s something is very wrong.
    ok($elapsed < 10, 'completed in under 10s')
        or diag "Took ${elapsed}s -- IPC notification may not be waking the event loop";

    $spawn->finish;
    $spawn->wait;
    ok(!kill(0, $spawn->pid), 'service exited cleanly');
};

done_testing;
