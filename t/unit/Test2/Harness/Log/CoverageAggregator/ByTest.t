use Test2::V0 -target => 'Test2::Harness::Log::CoverageAggregator::ByTest';

subtest 'init sets up defaults' => sub {
    my $agg = CLASS->new;
    is(ref($agg->in_progress), 'HASH',  "in_progress is a hashref");
    is(ref($agg->completed),   'ARRAY', "completed is an arrayref");
};

subtest 'start_test creates in-progress entry' => sub {
    my $agg = CLASS->new;
    $agg->start_test('t/foo.t');
    ok(exists $agg->in_progress->{'t/foo.t'}, "in_progress entry created");
    is($agg->in_progress->{'t/foo.t'}->{test}, 't/foo.t', "test name recorded");
    is(ref($agg->in_progress->{'t/foo.t'}->{files}), 'HASH', "files hash created");
};

subtest 'stop_test moves to completed' => sub {
    my $agg = CLASS->new;
    $agg->start_test('t/bar.t');
    $agg->stop_test('t/bar.t');

    ok(!exists $agg->in_progress->{'t/bar.t'}, "removed from in_progress");
    is(scalar @{$agg->completed}, 1, "added to completed");
    is($agg->completed->[0]->{test}, 't/bar.t', "completed entry has test name");
};

subtest 'touch records coverage for in-progress test' => sub {
    my $agg = CLASS->new;
    $agg->start_test('t/touch.t');

    $agg->touch(source => 'lib/Mod.pm', sub => 'my_func', test => 't/touch.t', manager_data => undef);

    ok(exists $agg->in_progress->{'t/touch.t'}->{files}->{'lib/Mod.pm'}->{my_func},
        "coverage recorded for file/sub");
};

subtest 'touch accumulates array manager data' => sub {
    my $agg = CLASS->new;
    $agg->start_test('t/arr.t');

    $agg->touch(source => 'lib/A.pm', sub => 's1', test => 't/arr.t', manager_data => ['line1']);
    $agg->touch(source => 'lib/A.pm', sub => 's1', test => 't/arr.t', manager_data => ['line2']);

    my $set = $agg->in_progress->{'t/arr.t'}->{files}->{'lib/A.pm'}->{s1};
    is($set, ['line1', 'line2'], "array manager_data accumulated without duplicates");
};

subtest 'flush returns completed and clears queue' => sub {
    my $agg = CLASS->new;
    $agg->start_test('t/flush.t');
    $agg->stop_test('t/flush.t');

    my $flushed = $agg->flush;
    ok(defined $flushed, "flush returns data");
    is(scalar @{$agg->completed}, 0, "completed cleared after flush");
};

subtest 'process_event full lifecycle' => sub {
    my $agg = CLASS->new;

    $agg->process_event({
        job_id     => 'j1',
        facet_data => {harness_job_start => {rel_file => 't/life.t'}},
    });

    $agg->process_event({
        job_id     => 'j1',
        facet_data => {coverage => {files => {'lib/Life.pm' => {run => 1}}}},
    });

    # process_event with harness_job_end triggers stop_test and write/flush,
    # which clears the completed array. Capture the return value (flushed list).
    my $flushed = $agg->process_event({
        job_id     => 'j1',
        facet_data => {harness_job_end => {rel_file => 't/life.t'}},
    });

    ok(defined $flushed && @$flushed, "flushed list returned by process_event");
    is($flushed->[0]->{test}, 't/life.t', "correct test name in flushed entry");
    ok(exists $flushed->[0]->{files}->{'lib/Life.pm'}, "coverage data in flushed entry");
};

done_testing;
