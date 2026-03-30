use Test2::V0 -target => 'Test2::Harness::Event';

sub make_event {
    my (%extra) = @_;
    return CLASS->new(
        job_id     => 'j1',
        facet_data => {
            harness => {
                event_id => 'e1',
                run_id   => 'r1',
                job_id   => 'j1',
                job_try  => 0,
            },
            trace => {stamp => 12345},
        },
        %extra,
    );
}

subtest 'constructor requires facet_data' => sub {
    like(
        dies { CLASS->new(job_id => 'j1') },
        qr/facet_data.*required/,
        "dies without facet_data"
    );
};

subtest 'constructor requires event_id' => sub {
    like(
        dies {
            CLASS->new(
                job_id     => 'j1',
                facet_data => {
                    harness => {run_id => 'r1', job_id => 'j1', job_try => 0},
                    trace   => {stamp => 12345},
                },
            )
        },
        qr/event_id.*required/,
        "dies without event_id"
    );
};

subtest 'basic accessors' => sub {
    my $e = make_event();
    is($e->event_id, 'e1',    "event_id");
    is($e->run_id,   'r1',    "run_id");
    is($e->job_id,   'j1',    "job_id");
    is($e->job_try,  0,       "job_try");
    is($e->stamp,    12345,   "stamp from trace");
};

subtest 'trace shortcut' => sub {
    my $e = make_event();
    is($e->trace, {stamp => 12345}, "trace returns facet_data->{trace}");
};

subtest 'facet_data accessor' => sub {
    my $e = make_event();
    ok(ref($e->facet_data) eq 'HASH', "facet_data returns hashref");
    ok(exists $e->facet_data->{harness}, "harness key present");
};

subtest 'as_json returns JSON string' => sub {
    my $e = make_event();
    my $json = $e->as_json;
    ok(defined $json && length($json), "as_json returns non-empty string");
    like($json, qr/"event_id"\s*:\s*"e1"/, "JSON contains event_id");
};

subtest 'as_json is cached' => sub {
    my $e = make_event();
    my $json1 = $e->as_json;
    my $json2 = $e->as_json;
    is($json1, $json2, "as_json returns same cached value on repeated calls");
    # The cache is stored in the object's +JSON slot
    ok(defined $e->{json}, "JSON cached in object after first call");
};

subtest 'TO_JSON omits sensitive fields' => sub {
    my $e = make_event();
    # Inject some internal-only state
    $e->{processed} = 1;
    $e->facet_data->{harness_job_watcher} = {secret => 1};

    my $to_json = $e->TO_JSON;
    ok(!exists $to_json->{processed},                                 "processed removed by TO_JSON");
    ok(!exists $to_json->{facet_data}->{harness_job_watcher},        "harness_job_watcher removed");
};

subtest 'isa Test2::Event' => sub {
    my $e = make_event();
    isa_ok($e, 'Test2::Event');
};

done_testing;
