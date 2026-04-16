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
    my $jid = $run->jobs->[0]->job_id;

    $run->mark_running($jid);
    is($run->pending, [],     'pending empty');
    is($run->running, [$jid], 'running has job');

    $run->mark_done($jid);
    is($run->running, [],     'running empty');
    is($run->done,    [$jid], 'done has job');
    ok($run->is_complete, 'run is complete');
};

subtest 'requires files' => sub {
    my $ok = eval { Test2::Harness2::Run->from_files(); 1 };
    ok(!$ok, 'croaks without files');
};

done_testing;
