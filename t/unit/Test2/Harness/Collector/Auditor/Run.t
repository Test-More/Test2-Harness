use Test2::V0 -target => 'Test2::Harness::Collector::Auditor::Run';

my $CLASS = CLASS();

subtest 'inherits from Auditor' => sub {
    ok($CLASS->isa('Test2::Harness::Collector::Auditor'), "inherits from Auditor");
};

subtest 'constructor with no args' => sub {
    my $obj = $CLASS->new();
    ok($obj, "object created with no args");
    is($obj->launches, 0,  "launches starts at 0");
    is($obj->asserts,  0,  "asserts starts at 0");
    ok(ref($obj->jobs) eq 'HASH', "jobs is a hash ref");
    ok(ref($obj->times) eq 'ARRAY', "times is an array ref");
    is(scalar @{$obj->times}, 4, "times has 4 elements");
};

subtest 'has_plan returns undef' => sub {
    my $obj = $CLASS->new();
    ok(!defined $obj->has_plan, "has_plan returns undef");
};

subtest 'has_exit returns undef' => sub {
    my $obj = $CLASS->new();
    ok(!defined $obj->has_exit, "has_exit returns undef");
};

subtest 'pass and fail with no jobs' => sub {
    my $obj = $CLASS->new();
    ok($obj->pass, "passes when no jobs");
    is($obj->fail, 0, "fail returns 0 when no jobs");
};

subtest 'exit_value with no failures' => sub {
    my $obj = $CLASS->new();
    is($obj->exit_value, 0, "exit_value is 0 when passing");
};

subtest 'final_data with no jobs' => sub {
    my $obj = $CLASS->new();
    my $fd = $obj->final_data;
    ok(ref($fd) eq 'HASH', "final_data returns a hash ref");
    ok($fd->{pass}, "pass is true with no jobs");
};

subtest 'summary with no data' => sub {
    my $obj = $CLASS->new();
    my $s = $obj->summary;
    ok(ref($s) eq 'HASH', "summary returns a hash ref");
    is($s->{tests_seen},     0, "tests_seen is 0");
    is($s->{asserts_seen},   0, "asserts_seen is 0");
    is($s->{failures},       0, "failures is 0");
};

subtest 'audit with a passing job end event' => sub {
    my $obj = $CLASS->new();

    my $e = {
        stamp      => time(),
        event_id   => 'evt-1',
        facet_data => {
            harness => {
                job_id  => 'job-1',
                job_try => 0,
                stamp   => time(),
            },
            harness_job_launch => { job_id => 'job-1' },
        },
    };

    my @out = $obj->audit($e);
    is($obj->launches, 1, "launches incremented");

    my $end_event = {
        stamp      => time(),
        event_id   => 'evt-2',
        facet_data => {
            harness => {
                job_id  => 'job-1',
                job_try => 0,
                stamp   => time(),
            },
            harness_job_end => {
                job_id => 'job-1',
                fail   => 0,
                file   => 't/example.t',
            },
        },
    };

    $obj->audit($end_event);

    my $fd = $obj->final_data;
    ok($fd->{pass}, "run passes after passing job end");
    ok(!$fd->{failed}, "no failed jobs");
};

subtest 'audit with a failing job end event' => sub {
    my $obj = $CLASS->new();

    my $launch = {
        stamp      => time(),
        event_id   => 'evt-a',
        facet_data => {
            harness => {
                job_id  => 'job-X',
                job_try => 0,
                stamp   => time(),
            },
            harness_job_launch => { job_id => 'job-X' },
        },
    };

    my $end = {
        stamp      => time(),
        event_id   => 'evt-b',
        facet_data => {
            harness => {
                job_id  => 'job-X',
                job_try => 0,
                stamp   => time(),
            },
            harness_job_end => {
                job_id => 'job-X',
                fail   => 1,
                file   => 't/fail.t',
            },
        },
    };

    $obj->audit($launch, $end);

    ok($obj->fail, "fail returns nonzero after failed job");
    ok(!$obj->pass, "pass returns false after failed job");
    is($obj->exit_value, 1, "exit_value is 1 after one failure");
};

subtest 'subtest_name with assert details' => sub {
    my $obj = $CLASS->new();
    my $f = { assert => { details => 'my subtest' } };
    is($obj->subtest_name($f), 'my subtest', "subtest_name returns assert details");
};

subtest 'subtest_name without trace or assert' => sub {
    my $obj = $CLASS->new();
    my $f = { assert => {} };
    is($obj->subtest_name($f), 'Unknown Subtest', "subtest_name returns Unknown Subtest when no details/trace");
};

subtest 'exit_value capped at 255' => sub {
    my $obj = $CLASS->new();

    # Inject 300 failed jobs directly
    for my $i (1 .. 300) {
        my $jid = "job-$i";
        $obj->{jobs}{$jid} = [{ result => 0, launched => 1 }];
    }

    ok($obj->exit_value <= 255, "exit_value capped at 255");
    is($obj->exit_value, 255, "exit_value is exactly 255 for 300 failures");
};

done_testing;
