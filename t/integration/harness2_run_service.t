use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/time sleep/;
use POSIX qw/:sys_wait_h/;
use Cpanel::JSON::XS qw/decode_json/;

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

sub read_jsonl {
    my ($path) = @_;
    return () unless -e $path;
    open my $fh, '<', $path or return ();
    my @events = map { decode_json($_) } grep { /\S/ } <$fh>;
    close $fh;
    return @events;
}

subtest 'run service writes its own jsonl log under runs/<run_id>/services' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # A trivial test file so the harness has work to kick off, which is
    # what triggers the lazy run-service spawn.
    my $tf = "$dir/ok.t";
    open my $fh, '>', $tf or die $!;
    print $fh "use Test2::V0; ok(1); done_testing;\n";
    close $fh;

    my $spawn = Test2::Harness2->spawn(
        workdir      => $dir,
        loggers      => classic_harness_loggers($dir),
        test_loggers => classic_test_loggers(),
    );
    my $q     = $spawn->queue_test_run(files => [Test2::Harness2::TestFile->new(file => $tf)]);
    ok($q->{ok}, 'queued') or diag explain $q;

    # Drain the run.
    wait_until(
        sub {
            my $s = $spawn->status;
            return !@{$s->{queue}} && !@{$s->{running} // []};
        },
        15,
    ) or die "run did not drain";

    $spawn->finish;
    $spawn->wait;

    # Find the run_id directory under runs/.
    opendir my $rdh, "$dir/logs/runs" or die "open $dir/runs: $!";
    my @runs = grep { !/^\./ && !/\.json$/ } readdir $rdh;
    closedir $rdh;
    is(scalar @runs, 1, 'one run dir written');
    my $run_dir = "$dir/logs/runs/$runs[0]";

    ok(-d "$run_dir/services", 'per-run services dir created');

    my $run_log = "$run_dir/services/run.jsonl";
    ok(-e $run_log, 'per-run run.jsonl exists');

    my @events = read_jsonl($run_log);
    my %kinds  = map { ($_->{facet_data}{harness}{kind} // '') => 1 } @events;
    ok($kinds{service_started}, 'run service emitted service_started');
    ok($kinds{service_stopped}, 'run service emitted service_stopped');
};

subtest "run service runs in its own process and is a child of the harness" => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $tf = "$dir/ok.t";
    open my $fh, '>', $tf or die $!;
    print $fh "use Test2::V0; ok(1); done_testing;\n";
    close $fh;

    my $spawn = Test2::Harness2->spawn(
        workdir      => $dir,
        loggers      => classic_harness_loggers($dir),
        test_loggers => classic_test_loggers(),
    );
    $spawn->queue_test_run(files => [Test2::Harness2::TestFile->new(file => $tf)]);

    # Drain the run so the collector has a chance to flush both logs.
    wait_until(
        sub {
            my $s = $spawn->status;
            return !@{$s->{queue}} && !@{$s->{running} // []};
        },
        15,
    ) or die "run did not drain";

    $spawn->finish;
    $spawn->wait;

    # Dig the run-id directory out, read both logs.
    opendir my $rdh, "$dir/logs/runs" or die "open $dir/runs: $!";
    my @runs = grep { !/^\./ && !/\.json$/ } readdir $rdh;
    closedir $rdh;
    my $run_log  = "$dir/logs/runs/$runs[0]/services/run.jsonl";
    my $harn_log = "$dir/logs/services/harness.jsonl";

    my @run_started = grep { ($_->{facet_data}{harness}{kind} // '') eq 'service_started' } read_jsonl($run_log);
    my @har_started = grep { ($_->{facet_data}{harness}{kind} // '') eq 'service_started' } read_jsonl($harn_log);
    is(scalar @run_started, 1, 'exactly one service_started event in run.jsonl');
    is(scalar @har_started, 1, 'exactly one service_started event in harness.jsonl');

    my $run_pid  = $run_started[0]->{facet_data}{harness}{pid};
    my $harn_pid = $har_started[0]->{facet_data}{harness}{pid};
    ok($run_pid,  'run service reported a pid');
    ok($harn_pid, 'harness reported a pid');
    isnt($run_pid, $harn_pid, 'run-service pid differs from harness pid');
};

done_testing;
