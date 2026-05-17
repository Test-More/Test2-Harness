use Test2::V0;
use File::Temp qw/tempdir/;

use Test2::Harness2;
use Test2::Harness2::Run;
use Test2::Harness2::Resource::JobCount;

my $RUN_A = '11111111-1111-1111-1111-111111111111';
my $RUN_B = '22222222-2222-2222-2222-222222222222';

sub _new_harness {
    my $dir = tempdir(CLEANUP => 1);
    return Test2::Harness2->new(workdir => $dir);
}

subtest register_and_lookup => sub {
    my $h = _new_harness;

    $h->pid_index->register($RUN_A, 1001, kind => 'collector', job_id => 'j1');
    $h->pid_index->register($RUN_A, 1002, kind => 'collector', job_id => 'j2');
    $h->pid_index->register($RUN_B, 2001, kind => 'collector', job_id => 'j3');

    is(
        [sort { $a <=> $b } $h->pid_index->pids_for_run($RUN_A)],
        [1001, 1002],
        'pids_for_run isolates by run',
    );
    is([$h->pid_index->pids_for_run($RUN_B)], [2001], 'run B sees its own pid only');
    is([$h->pid_index->pids_for_run('does-not-exist')], [], 'unknown run returns empty');

    my ($run_key, $meta) = $h->pid_index->run_for_pid(1002);
    is($run_key, $RUN_A, 'run_for_pid resolves run');
    is($meta->{kind}, 'collector', 'meta carries kind');
    is($meta->{job_id}, 'j2', 'meta carries job_id');
    ok($meta->{started_at}, 'started_at auto-stamped');

    is([$h->pid_index->run_for_pid(9999)], [undef, undef], 'unknown pid returns (undef,undef)');
};

subtest forget_drops_empty_bucket => sub {
    my $h = _new_harness;

    $h->pid_index->register($RUN_A, 1001, kind => 'collector');
    $h->pid_index->register($RUN_A, 1002, kind => 'collector');

    my $meta = $h->pid_index->forget($RUN_A, 1001);
    is($meta->{kind}, 'collector', 'forget returns the dropped meta');
    ok(exists $h->pid_index->{run_pids}{$RUN_A}, 'bucket retained while still populated');

    $h->pid_index->forget($RUN_A, 1002);
    ok(!exists $h->pid_index->{run_pids}{$RUN_A}, 'bucket removed when last pid leaves');

    is($h->pid_index->forget($RUN_A, 9999), undef, 'forget on missing pid is a no-op');
    is($h->pid_index->forget('no-such-run', 1), undef, 'forget on missing run is a no-op');
};

subtest kill_run_isolation => sub {
    my $h = _new_harness;

    # Use $$ as a stand-in for "definitely a live pid" -- signal 0 is a
    # liveness probe, not a real signal, so this neither hurts the test
    # process nor leaks a child.
    $h->pid_index->register($RUN_A, $$, kind => 'collector');
    $h->pid_index->register($RUN_B, 999_999, kind => 'collector');

    my $sent = $h->pid_index->kill_run($RUN_A, 0);
    is($sent, 1, 'kill_run delivered to live pid in run A');

    $sent = $h->pid_index->kill_run($RUN_B, 0);
    is($sent, 0, 'kill_run skips dead pid in run B (no fake delivery)');

    is($h->pid_index->kill_run('no-such-run', 0), 0, 'kill_run on empty run returns 0');
};

subtest await_run_exit_timeout => sub {
    my $h = _new_harness;

    $h->pid_index->register($RUN_A, 99_998, kind => 'collector');
    my $start = Time::HiRes::time();
    my $ok    = $h->pid_index->await_run_exit($RUN_A, $start + 0.1);
    my $waited = Time::HiRes::time() - $start;

    is($ok, 0, 'await returns 0 on deadline');
    ok($waited >= 0.05, 'waited at least to the deadline');
    ok($waited < 1.5,   'did not block much beyond the deadline');

    $h->pid_index->forget($RUN_A, 99_998);
    is($h->pid_index->await_run_exit($RUN_A, time + 5), 1, 'await returns 1 immediately when run is empty');
};

subtest resource_service_hooks_register => sub {
    my $h = _new_harness;

    my $jc = Test2::Harness2::Resource::JobCount->new(slots => 4);

    $h->pid_index->resource_service_tracked(
        pid      => 4321,
        scope    => 'global',
        run      => undef,
        name     => 'jobcount',
        resource => $jc,
    );
    my ($run_key, $meta) = $h->pid_index->run_for_pid(4321);
    is($run_key, '__global__', 'global resource service registered under __global__ key');
    is($meta->{kind}, 'resource_service', 'kind tagged');
    is($meta->{res_svc}, 'jobcount', 'service name carried');
    is($meta->{scope}, 'global', 'scope carried');

    my $run = Test2::Harness2::Run->new(
        run_id   => $RUN_A,
        run_uuid => $RUN_A,
        jobs     => [],
        resources => [],
    );
    $h->pid_index->resource_service_tracked(
        pid      => 5678,
        scope    => 'run',
        run      => $run,
        name     => 'percpu',
        resource => $jc,
    );
    ($run_key) = $h->pid_index->run_for_pid(5678);
    is($run_key, $RUN_A, 'per-run resource service keyed by run_id');

    $h->pid_index->resource_service_forgotten(
        pid   => 4321,
        scope => 'global',
        run   => undef,
        name  => 'jobcount',
    );
    is([$h->pid_index->run_for_pid(4321)], [undef, undef], 'global service forgotten');

    $h->pid_index->resource_service_forgotten(
        pid   => 5678,
        scope => 'run',
        run   => $run,
        name  => 'percpu',
    );
    is([$h->pid_index->run_for_pid(5678)], [undef, undef], 'per-run service forgotten');
};

done_testing;
