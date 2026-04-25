use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/time sleep/;

use Test2::Util qw/IS_WIN32/;
plan skip_all => 'preload requires Unix (fork + goto::file)' if IS_WIN32;

use lib 't/lib';
use Test2::Harness2::TestFile;
use Test2::Harness2::Test::Loggers   qw/classic_harness_loggers classic_test_loggers/;
use Test2::Harness2::Test::SpawnRace qw/finish_and_wait/;

use Test2::Harness2;
use Test2::Harness2::Resource::JobCount;
use Test2::Harness2::Resource::Preload;

sub wait_until {
    my ($check, $timeout_sec) = @_;
    my $deadline = time + $timeout_sec;
    while (time < $deadline) {
        return 1 if $check->();
        sleep(0.05);
    }
    return 0;
}

subtest 'test launched via preload stage sees env var and preloaded module' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # The test script verifies it is running in preload mode and that the
    # preloaded module is visible in %INC (inherited from the stage fork).
    my $tf_path = "$dir/preloaded_test.t";
    open my $fh, '>', $tf_path or die "Cannot write test file: $!";
    print $fh "use Test2::V0;\n";
    print $fh "ok(\$ENV{T2_HARNESS_PRELOAD}, 'T2_HARNESS_PRELOAD env set by Collector::Preloaded');\n";
    print $fh "ok(\$INC{'Scalar/Util.pm'}, 'Scalar::Util preloaded into %INC by the stage service');\n";
    print $fh "done_testing;\n";
    close $fh;

    my $preload_res = Test2::Harness2::Resource::Preload->new(
        preloads => ['Scalar::Util'],
    );

    my $spawn = Test2::Harness2->spawn(
        workdir   => $dir,
        resources => [
            Test2::Harness2::Resource::JobCount->new(slots => 4),
            $preload_res,
        ],
        loggers      => classic_harness_loggers($dir),
        test_loggers => classic_test_loggers(),
    );

    my $queued = $spawn->queue_test_run(
        files => [Test2::Harness2::TestFile->new(file => $tf_path)],
    );
    ok($queued->{ok}, 'run queued') or diag explain $queued;
    my $run_id = $queued->{run_id};

    # Poll until the run reports complete. The preload stage needs to come
    # up before the scheduler dispatches the job, which adds a few seconds.
    my $service_gone_re = qr/peer .* went away|is not a valid message recipient/;
    my $timeout         = 60;
    my $deadline        = time + $timeout;
    my $final;
    my $service_gone;
    while (time < $deadline) {
        my $resp = eval { $spawn->run_results(run_id => $run_id) };
        my $err  = $@;
        if (!defined $resp) {
            last unless $err =~ $service_gone_re;
            $service_gone = 1;
            last;
        }
        next unless $resp->{ok};
        if (($resp->{state} // '') eq 'complete') {
            $final = $resp;
            last;
        }
        sleep(0.1);
    }

    ok(defined $final || $service_gone, 'run completed or service exited cleanly');
    ok(!$service_gone, 'service did not disappear unexpectedly')
        unless defined $final;

    finish_and_wait($spawn);

    SKIP: {
        skip 'no final result (service gone before reporting)', 1 unless $final;
        ok($final->{pass}, 'run passed — test assertions verified preload mode');
    }
};

done_testing;
