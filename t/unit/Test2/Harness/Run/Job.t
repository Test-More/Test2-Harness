use Test2::V0 -target => 'Test2::Harness::Run::Job';
use File::Temp qw/tempfile/;

sub make_test_file_path {
    my ($content) = @_;
    my ($fh, $file) = tempfile(SUFFIX => '.t', UNLINK => 1);
    print $fh $content // "use Test2::V0;\ndone_testing;\n";
    close $fh;
    return $file;
}

sub make_job {
    my %extra = @_;
    my $file = make_test_file_path();
    return $CLASS->new(test_file => {file => $file}, %extra);
}

subtest 'test_file is required' => sub {
    like(
        dies { $CLASS->new },
        qr/test_file.*required/i,
        'test_file is required',
    );
};

subtest 'basic construction' => sub {
    my $job = make_job();
    ok($job->isa($CLASS), 'creates instance');
    ok($job->test_file->isa('Test2::Harness::TestFile'), 'test_file inflated to TestFile object');
};

subtest 'job_id auto-generated' => sub {
    my $job = make_job();
    ok($job->job_id, 'job_id is auto-generated');
    like($job->job_id, qr/\w/, 'job_id looks non-empty');
};

subtest 'job_id can be specified' => sub {
    my $job = make_job(job_id => 'my-job-123');
    is($job->job_id, 'my-job-123', 'explicit job_id preserved');
};

subtest 'try counts result attempts' => sub {
    my $job = make_job();
    is($job->try, 0, 'try is 0 before any results');

    push @{$job->{results}}, {pass => 0};
    is($job->try, 1, 'try is 1 after one result');

    push @{$job->{results}}, {pass => 1};
    is($job->try, 2, 'try is 2 after two results');
};

subtest 'resource_id combines job_id and try' => sub {
    my $job = make_job(job_id => 'abc-123');
    is($job->resource_id, 'abc-123:0', 'resource_id is job_id:try at 0 results');

    push @{$job->{results}}, {pass => 0};
    is($job->resource_id, 'abc-123:1', 'resource_id updates when try changes');
};

subtest 'TO_JSON includes job_class' => sub {
    my $job  = make_job();
    my $json = $job->TO_JSON;
    ref_ok($json, 'HASH', 'TO_JSON returns hashref');
    is($json->{job_class}, $CLASS, 'TO_JSON includes job_class');
    ok(exists($json->{job_id}), 'TO_JSON includes job_id');
};

subtest 'process_info excludes test_file and results' => sub {
    my $job  = make_job();
    my $info = $job->process_info;
    ref_ok($info, 'HASH', 'process_info returns hashref');
    ok(!exists($info->{test_file}), 'process_info excludes test_file');
    ok(!exists($info->{results}),   'process_info excludes results');
    ok(exists($info->{job_id}),     'process_info includes job_id');
};

done_testing;
