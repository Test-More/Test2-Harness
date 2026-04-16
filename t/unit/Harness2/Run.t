use Test2::V0;
use Test2::Harness2::Run;

subtest 'from_files builds jobs with inherited run_id' => sub {
    my $run = Test2::Harness2::Run->from_files(
        run_id => 'run-1',
        files  => ['t/a.t', 't/b.t'],
    );
    is($run->run_id,               'run-1', 'run_id set');
    is(scalar @{$run->jobs},       2,       'two jobs');
    is($run->jobs->[0]->run_id,    'run-1', 'job inherits run_id');
    is($run->jobs->[0]->test_file, 't/a.t');
    is($run->jobs->[1]->test_file, 't/b.t');
    is(scalar @{$run->pending},    2, 'both pending');
    is(scalar @{$run->running},    0, 'none running');
    is(scalar @{$run->done},       0, 'none done');
};

subtest 'auto-generates run_id' => sub {
    my $run = Test2::Harness2::Run->from_files(files => ['t/x.t']);
    like($run->run_id, qr/^[0-9A-F-]{36}$/i, 'UUID run_id');
};

subtest 'mark_running / mark_done move job through states' => sub {
    my $run = Test2::Harness2::Run->from_files(files => ['t/a.t']);
    my $job_id = $run->jobs->[0]->job_id;

    $run->mark_running($job_id);
    is($run->pending, [],         'pending empty');
    is($run->running, [$job_id], 'running has job');

    $run->mark_done($job_id);
    is($run->running, [],         'running empty');
    is($run->done,    [$job_id], 'done has job');
    ok($run->is_complete, 'run is complete');
};

subtest 'requires files' => sub {
    my $ok = eval { Test2::Harness2::Run->from_files(); 1 };
    ok(!$ok, 'croaks without files');
};

subtest 'mark_running croaks on unknown job_id' => sub {
    my $run = Test2::Harness2::Run->from_files(files => ['t/a.t']);
    my $ok  = eval { $run->mark_running('not-a-real-id'); 1 };
    ok(!$ok, 'croaked');
    like($@, qr/not pending/);
};

subtest 'mark_done croaks when job is not running' => sub {
    my $run = Test2::Harness2::Run->from_files(files => ['t/a.t']);
    my $job_id = $run->jobs->[0]->job_id;
    my $ok  = eval { $run->mark_done($job_id); 1 };                      # never marked running
    ok(!$ok, 'croaked');
    like($@, qr/not running/);
};

subtest 'mark_* preserves FIFO order across multiple jobs' => sub {
    my $run  = Test2::Harness2::Run->from_files(files => ['t/a.t', 't/b.t', 't/c.t']);
    my @jids = map { $_->job_id } @{$run->jobs};
    $run->mark_running($_) for @jids;
    is($run->running, \@jids, 'running preserves queue order');
    $run->mark_done($_) for reverse @jids;
    is($run->done, [reverse @jids], 'done reflects completion order, not queue order');
};

subtest 'empty run with no jobs is vacuously complete' => sub {
    my $run = Test2::Harness2::Run->new;
    ok($run->is_complete,        'empty run is complete');
    ok(defined $run->created_at, 'created_at populated');
    ok(defined $run->run_id,     'run_id populated');
};

subtest 'from_files rejects non-arrayref files' => sub {
    my $ok = eval { Test2::Harness2::Run->from_files(files => 'not-an-array'); 1 };
    ok(!$ok, 'croaked');
    like($@, qr/arrayref/);
};

done_testing;
