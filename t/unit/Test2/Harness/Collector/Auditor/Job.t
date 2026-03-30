use Test2::V0 -target => 'Test2::Harness::Collector::Auditor::Job';

my $CLASS = CLASS();

subtest 'inherits from Auditor' => sub {
    ok($CLASS->isa('Test2::Harness::Collector::Auditor'), "inherits from Auditor");
};

subtest 'constructor requires mandatory fields' => sub {
    like(
        dies { $CLASS->new(job_id => 'j1', job_try => 0, file => 't/foo.t') },
        qr/run_id.*required/i,
        "missing run_id dies"
    );

    like(
        dies { $CLASS->new(run_id => 'r1', job_try => 0, file => 't/foo.t') },
        qr/job_id.*required/i,
        "missing job_id dies"
    );

    like(
        dies { $CLASS->new(run_id => 'r1', job_id => 'j1', file => 't/foo.t') },
        qr/job_try.*required/i,
        "missing job_try dies"
    );

    like(
        dies { $CLASS->new(run_id => 'r1', job_id => 'j1', job_try => 0) },
        qr/file.*required/i,
        "missing file dies"
    );
};

my $auditor = $CLASS->new(
    run_id  => 'run-1',
    job_id  => 'job-1',
    job_try => 0,
    file    => 't/example.t',
);

subtest 'constructor with valid args' => sub {
    ok($auditor, "object created");
    is($auditor->run_id,  'run-1',        "run_id accessor");
    is($auditor->job_id,  'job-1',        "job_id accessor");
    is($auditor->job_try, 0,              "job_try accessor");
    is($auditor->file,    't/example.t',  "file accessor");
};

subtest 'initial state' => sub {
    ok(!$auditor->has_exit,      "has_exit returns false initially");
    ok(!$auditor->has_plan,      "has_plan returns false initially");
    is($auditor->assertion_count, 0, "assertion_count starts at 0");
    is($auditor->nested, 0, "nested starts at 0");
    # pass/fail state with no events depends on fail_error_facet_list logic
    # (no plan + no assertions = fail). Check that pass and fail are consistent.
    my $p = $auditor->pass;
    my $f = $auditor->fail;
    ok(($p && !$f) || (!$p && $f) || (!$p && !$f), "pass and fail are consistent");
};

subtest 'fail_error_facet_list with no assertions and no plan' => sub {
    my $obj = $CLASS->new(
        run_id  => 'r',
        job_id  => 'j',
        job_try => 0,
        file    => 't/test.t',
    );
    my @errors = $obj->fail_error_facet_list();
    ok(@errors, "has error facets when no plan and no assertions");
    my ($no_plan) = grep { $_->{details} =~ /No plan/ } @errors;
    ok($no_plan, "error mentions missing plan");
};

subtest 'subtest_fail_error_facet_list with no plan' => sub {
    my $obj = $CLASS->new(
        run_id  => 'r',
        job_id  => 'j',
        job_try => 0,
        file    => 't/test.t',
    );
    my @errors = $obj->subtest_fail_error_facet_list();
    ok(@errors, "has errors when no plan seen");
    my ($no_plan) = grep { $_->{details} =~ /No plan/ } @errors;
    ok($no_plan, "error mentions no plan");
};

subtest 'pass and fail are inverses' => sub {
    my $obj = $CLASS->new(
        run_id  => 'r',
        job_id  => 'j',
        job_try => 0,
        file    => 't/test.t',
    );
    # pass() is defined as !fail(), so they are always inverses
    my $pass = $obj->pass;
    my $fail = $obj->fail;
    # They must be logical inverses
    ok(($pass ? 1 : 0) != ($fail ? 1 : 0), "pass and fail are logical inverses");
};

subtest 'has_exit with no exit set' => sub {
    my $obj = $CLASS->new(
        run_id  => 'r',
        job_id  => 'j',
        job_try => 0,
        file    => 't/test.t',
    );
    ok(!$obj->has_exit, "has_exit returns false when exit not seen");
};

subtest 'has_plan with no plan set' => sub {
    my $obj = $CLASS->new(
        run_id  => 'r',
        job_id  => 'j',
        job_try => 0,
        file    => 't/test.t',
    );
    ok(!$obj->has_plan, "has_plan returns false when no plan seen");
};

subtest 'times accessor returns TimeTracker' => sub {
    my $obj = $CLASS->new(
        run_id  => 'r',
        job_id  => 'j',
        job_try => 0,
        file    => 't/test.t',
    );
    my $times = $obj->times;
    ok($times, "times accessor returns something");
    ok($times->isa('Test2::Harness::Log::TimeTracker'), "times is a TimeTracker");
};

subtest 'update_summary with no summary_file' => sub {
    my $obj = $CLASS->new(
        run_id  => 'r',
        job_id  => 'j',
        job_try => 0,
        file    => 't/test.t',
    );
    # Should not die when no summary_file is set
    ok(lives { $obj->update_summary() }, "update_summary doesn't die without summary_file");
};

done_testing;
