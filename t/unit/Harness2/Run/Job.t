use Test2::V0;
use File::Spec ();
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
    ok(!$ok, 'croaks without test_file or test_file_abs');
    like($err, qr/test_file/, 'error mentions test_file');
};

subtest 'run_id is required' => sub {
    my $ok  = eval { Test2::Harness2::Run::Job->new(test_file => 't/foo.t'); 1 };
    my $err = $@;
    ok(!$ok, 'croaks without run_id');
    like($err, qr/run_id/, 'error mentions run_id');
};

subtest 'derives test_file_abs from test_file' => sub {
    my $job = Test2::Harness2::Run::Job->new(
        test_file => 't/foo.t',
        run_id    => 'r1',
    );
    ok(File::Spec->file_name_is_absolute($job->test_file_abs),
        'test_file_abs is absolute');
    like($job->test_file_abs, qr{\Qfoo.t\E\z}, 'test_file_abs ends with foo.t');
    is($job->test_file, 't/foo.t', 'test_file preserved as given');
};

subtest 'derives test_file from test_file_abs' => sub {
    my $abs = File::Spec->rel2abs('t/foo.t');
    my $job = Test2::Harness2::Run::Job->new(
        test_file_abs => $abs,
        run_id        => 'r1',
    );
    is($job->test_file_abs, $abs, 'test_file_abs kept as given');
    is($job->test_file,     File::Spec->abs2rel($abs), 'test_file derived');
};

subtest 'accepts both paths explicitly' => sub {
    my $abs = File::Spec->rel2abs('t/foo.t');
    my $job = Test2::Harness2::Run::Job->new(
        test_file     => 'display/foo.t',
        test_file_abs => $abs,
        run_id        => 'r1',
    );
    is($job->test_file,     'display/foo.t', 'relative kept as given');
    is($job->test_file_abs, $abs,            'absolute kept as given');
};

subtest 'absolute path supplied as test_file lands in test_file_abs' => sub {
    my $abs = File::Spec->rel2abs('t/foo.t');
    my $job = Test2::Harness2::Run::Job->new(
        test_file => $abs,           # caller did not know it was absolute
        run_id    => 'r1',
    );
    is($job->test_file_abs, $abs, 'classified as absolute');
    is($job->test_file, File::Spec->abs2rel($abs), 'relative derived from it');
};

subtest 'relative path supplied as test_file_abs lands in test_file' => sub {
    my $job = Test2::Harness2::Run::Job->new(
        test_file_abs => 't/foo.t',   # caller did not know it was relative
        run_id        => 'r1',
    );
    is($job->test_file, 't/foo.t', 'classified as relative');
    ok(File::Spec->file_name_is_absolute($job->test_file_abs),
        'test_file_abs derived as absolute');
    like($job->test_file_abs, qr{\Qfoo.t\E\z}, 'ends at the input file');
};

subtest 'TO_JSON returns a plain hash of all attributes' => sub {
    my $job = Test2::Harness2::Run::Job->new(
        job_id    => 'j-1',
        test_file => 't/foo.t',
        run_id    => 'r-1',
    );
    my $h = $job->TO_JSON;
    is(ref($h), 'HASH', 'returns a hashref');
    is($h->{job_id},  'j-1',     'job_id present');
    is($h->{run_id},  'r-1',     'run_id present');
    is($h->{test_file}, 't/foo.t', 'test_file present');
    ok($h->{test_file_abs}, 'test_file_abs present');
    is($h->{job_try}, 0, 'job_try present');
};

done_testing;
