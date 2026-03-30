use Test2::V0 -target => 'Test2::Harness::Log::CoverageAggregator';

subtest 'init sets up defaults' => sub {
    my $agg = CLASS->new;
    is(ref($agg->{touched}),  'HASH', "touched is a hashref");
    is(ref($agg->{job_map}),  'HASH', "job_map is a hashref");
};

subtest '_touch_coverage tracks files and subs' => sub {
    my $agg = CLASS->new;

    my $coverage = {files => {'lib/Foo.pm' => {foo_sub => 1, bar_sub => 1}}};
    $agg->_touch_coverage('t/foo.t', $coverage, {});

    ok(exists $agg->touched->{'lib/Foo.pm'},                     "file tracked");
    ok(exists $agg->touched->{'lib/Foo.pm'}->{foo_sub},         "foo_sub tracked");
    ok(exists $agg->touched->{'lib/Foo.pm'}->{bar_sub},         "bar_sub tracked");
    is($agg->touched->{'lib/Foo.pm'}->{foo_sub}, 1, "touch count");
};

subtest '_touch_coverage accumulates across tests' => sub {
    my $agg = CLASS->new;

    $agg->_touch_coverage('t/a.t', {files => {'lib/X.pm' => {sub1 => 1}}}, {});
    $agg->_touch_coverage('t/b.t', {files => {'lib/X.pm' => {sub1 => 1}}}, {});

    is($agg->touched->{'lib/X.pm'}->{sub1}, 2, "sub touched count accumulates");
};

subtest 'process_event handles start event' => sub {
    my $agg = CLASS->new;

    my $event = {
        job_id     => 'job1',
        facet_data => {
            harness_job_start => {rel_file => 't/mytest.t'},
        },
    };

    $agg->process_event($event);
    is($agg->job_map->{'job1'}, 't/mytest.t', "job mapped to test file on start");
};

subtest 'process_event handles coverage data' => sub {
    my $agg = CLASS->new;

    # First, start the job so we know which test it belongs to
    $agg->process_event({
        job_id     => 'j2',
        facet_data => {harness_job_start => {rel_file => 't/cov.t'}},
    });

    # Then send coverage
    $agg->process_event({
        job_id     => 'j2',
        facet_data => {
            coverage => {files => {'lib/Bar.pm' => {baz => 1}}},
        },
    });

    ok(exists $agg->touched->{'lib/Bar.pm'}, "coverage file tracked via process_event");
};

subtest 'process_event ignores empty events' => sub {
    my $agg = CLASS->new;
    ok(lives { $agg->process_event({}) },   "empty event is ignored");
    ok(lives { $agg->process_event(undef) }, "undef event is ignored");
};

done_testing;
