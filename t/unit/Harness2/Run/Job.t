use Test2::V0;
use Test2::Harness2::Run::Job;

subtest 'constructs with explicit fields' => sub {
    my $job = Test2::Harness2::Run::Job->new(
        job_id    => 'abc-123',
        test_file => 't/foo.t',
        run_id    => 'run-1',
    );
    is($job->job_id,    'abc-123', 'job_id');
    is($job->test_file, 't/foo.t', 'test_file');
    is($job->run_id,    'run-1',   'run_id');
    is($job->job_try,   0,         'job_try defaults to 0');
};

subtest 'auto-generates job_id when absent' => sub {
    my $job = Test2::Harness2::Run::Job->new(test_file => 't/foo.t', run_id => 'r1');
    like($job->job_id, qr/^[0-9A-F-]{36}$/i, 'UUID-shaped job_id');
};

subtest 'test_file is required' => sub {
    my $ok  = eval { Test2::Harness2::Run::Job->new(run_id => 'r1'); 1 };
    my $err = $@;
    ok(!$ok, 'croaks without test_file');
    like($err, qr/test_file/, 'error mentions test_file');
};

subtest 'run_id is required' => sub {
    my $ok  = eval { Test2::Harness2::Run::Job->new(test_file => 't/foo.t'); 1 };
    my $err = $@;
    ok(!$ok, 'croaks without run_id');
    like($err, qr/run_id/, 'error mentions run_id');
};

done_testing;
