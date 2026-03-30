use Test2::V0 -target => 'Test2::Harness::Log::CoverageAggregator::ByRun';

subtest 'init_coverage lazily creates coverage hash' => sub {
    my $agg = CLASS->new;
    ok(!defined $agg->coverage, "coverage starts undef");
    my $cov = $agg->init_coverage;
    ok(defined $cov, "init_coverage returns hashref");
    is(ref($cov), 'HASH', "coverage is a hashref");
    is($agg->coverage, $cov, "coverage stored after init");
};

subtest 'touch records per-file/sub/test coverage' => sub {
    my $agg = CLASS->new;

    $agg->touch(source => 'lib/Foo.pm', sub => 'run', test => 't/foo.t', manager_data => undef);

    my $files = $agg->coverage->{files};
    ok(exists $files->{'lib/Foo.pm'}, "file entry created");
    ok(exists $files->{'lib/Foo.pm'}->{run}, "sub entry created");
    ok(exists $files->{'lib/Foo.pm'}->{run}->{'t/foo.t'}, "test entry created");
};

subtest 'touch accumulates array manager data' => sub {
    my $agg = CLASS->new;

    $agg->touch(source => 'lib/X.pm', sub => 's', test => 't/x.t', manager_data => ['a']);
    $agg->touch(source => 'lib/X.pm', sub => 's', test => 't/x.t', manager_data => ['b']);

    my $set = $agg->coverage->{files}->{'lib/X.pm'}->{s}->{'t/x.t'};
    is($set, ['a', 'b'], "array data accumulated");
};

subtest 'record_coverage tracks test metadata' => sub {
    my $agg = CLASS->new;

    $agg->record_coverage('t/meta.t', {test_type => 'unit', from_manager => 'MyManager'});

    my $testmeta = $agg->coverage->{testmeta}->{'t/meta.t'};
    is($testmeta->{type},    'unit',      "test type recorded");
    is($testmeta->{manager}, 'MyManager', "manager recorded");
};

subtest 'flush is empty before finalize' => sub {
    my $agg = CLASS->new;
    $agg->touch(source => 'lib/A.pm', sub => 'x', test => 't/a.t', manager_data => undef);

    is($agg->flush, undef, "flush returns undef before finalize");
};

subtest 'flush returns coverage after finalize' => sub {
    my $agg = CLASS->new;
    $agg->touch(source => 'lib/B.pm', sub => 'y', test => 't/b.t', manager_data => undef);
    $agg->finalize;

    my $result = $agg->flush;
    ok(defined $result, "flush returns data after finalize");
    is(ref($result), 'ARRAY', "flush returns arrayref");
    ok(exists $result->[0]->{files}, "coverage data present");
};

subtest 'process_event lifecycle' => sub {
    my $agg = CLASS->new;

    $agg->process_event({
        job_id     => 'j1',
        facet_data => {harness_job_start => {rel_file => 't/run.t'}},
    });

    $agg->process_event({
        job_id     => 'j1',
        facet_data => {coverage => {files => {'lib/Run.pm' => {go => 1}}}},
    });

    $agg->process_event({
        job_id     => 'j1',
        facet_data => {harness_job_end => {rel_file => 't/run.t'}},
    });

    ok(exists $agg->touched->{'lib/Run.pm'}, "coverage tracked in touched map");
};

done_testing;
