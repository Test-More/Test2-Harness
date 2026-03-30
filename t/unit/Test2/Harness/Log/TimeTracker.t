use Test2::V0 -target => 'Test2::Harness::Log::TimeTracker';

subtest 'new creates empty tracker' => sub {
    my $t = CLASS->new;
    ok(!$t->useful, "not useful with no data");
};

subtest 'process tracks start and stop timestamps' => sub {
    my $t = CLASS->new;

    $t->process(
        {stamp => 100, event_id => 'e1'},
        {harness_job_start => {stamp => 100}},
        0,
    );

    $t->process(
        {stamp => 200, event_id => 'e2'},
        {harness_job_exit => {stamp => 200}},
        0,
    );

    ok($t->useful, "tracker has useful data after start+stop");
    is($t->source->{start}, 100, "start timestamp recorded");
    is($t->source->{stop},  200, "stop timestamp recorded");
};

subtest 'process records first and last event timestamps' => sub {
    my $t = CLASS->new;

    $t->process(
        {stamp => 110, event_id => 'e1'},
        {trace => {stamp => 110}},
        0,
    );

    $t->process(
        {stamp => 120, event_id => 'e2'},
        {trace => {stamp => 120}},
        0,
    );

    is($t->source->{first}, 110, "first event timestamp");
    is($t->source->{last},  120, "last event timestamp");
};

subtest 'totals computes time deltas' => sub {
    my $t = CLASS->new;

    # Simulate: start at 100, first event at 110, last event at 120, stop at 130
    $t->process({stamp => 100, event_id => 'e0'}, {harness_job_start => 1}, 0);
    $t->process({stamp => 110, event_id => 'e1'}, {trace => {stamp => 110}}, 0);
    $t->process({stamp => 120, event_id => 'e2'}, {trace => {stamp => 120}}, 0);
    $t->process({stamp => 130, event_id => 'e3'}, {harness_job_exit => 1}, 0);

    my $totals = $t->totals;
    ok(exists $totals->{startup}, "startup computed");
    ok(exists $totals->{events},  "events computed");
    ok(exists $totals->{cleanup}, "cleanup computed");
    ok(exists $totals->{total},   "total computed");

    is($totals->{startup}, 10,  "startup = first - start");
    is($totals->{events},  10,  "events = last - first");
    is($totals->{cleanup}, 10,  "cleanup = stop - last");
    is($totals->{total},   30,  "total = stop - start");
};

subtest 'summary produces readable string' => sub {
    my $t = CLASS->new;
    $t->process({stamp => 100, event_id => 'e0'}, {harness_job_start => 1}, 0);
    $t->process({stamp => 110, event_id => 'e1'}, {trace => {stamp => 110}}, 0);
    $t->process({stamp => 130, event_id => 'e3'}, {harness_job_exit => 1}, 0);

    my $summary = $t->summary;
    ok(defined $summary && length($summary), "summary is non-empty");
    like($summary, qr/Total/i, "summary mentions Total");
};

subtest 'table returns structured data' => sub {
    my $t = CLASS->new;
    $t->process({stamp => 100, event_id => 'e0'}, {harness_job_start => 1}, 0);
    $t->process({stamp => 110, event_id => 'e1'}, {trace => {stamp => 110}}, 0);
    $t->process({stamp => 130, event_id => 'e3'}, {harness_job_exit => 1}, 0);

    my $table = $t->table;
    is(ref($table), 'HASH', "table returns hashref");
    ok(exists $table->{header}, "table has header");
    ok(exists $table->{rows},   "table has rows");
    ok(scalar @{$table->{rows}} > 0, "table has at least one row");
};

subtest 'data_dump includes totals and source' => sub {
    my $t = CLASS->new;
    $t->process({stamp => 100, event_id => 'e0'}, {harness_job_start => 1}, 0);
    $t->process({stamp => 130, event_id => 'e3'}, {harness_job_exit => 1}, 0);

    my $dump = $t->data_dump;
    ok(exists $dump->{totals}, "data_dump has totals");
    ok(exists $dump->{source}, "data_dump has source");
};

done_testing;
