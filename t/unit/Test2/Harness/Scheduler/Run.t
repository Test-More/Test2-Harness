use Test2::V0 -target => 'Test2::Harness::Scheduler::Run';

# CLASS is Test2::Harness::Scheduler::Run which extends Test2::Harness::Run.
# Constructing a Run requires run_id, test_settings, and aggregator_ipc or
# aggregator_use_io.

my %base_args = (
    run_id            => 'test-run-1',
    aggregator_use_io => 1,
    test_settings     => { event_timeout => 60 },
);

subtest isa => sub {
    ok(CLASS->isa('Test2::Harness::Run'), "is a Test2::Harness::Run subclass");
};

subtest construction => sub {
    my $r = CLASS->new(%base_args);
    ok($r, "constructed");
    is($r->run_id, 'test-run-1', "run_id accessor");
};

subtest initial_collections => sub {
    my $r = CLASS->new(%base_args);

    is(ref($r->complete), 'ARRAY', "complete is an arrayref");
    is(ref($r->running),  'HASH',  "running is a hashref");
    is(ref($r->todo),     'HASH',  "todo is a hashref");
    is(scalar @{$r->complete}, 0, "complete starts empty");
    is(scalar keys %{$r->running}, 0, "running starts empty");
    is(scalar keys %{$r->todo},    0, "todo starts empty");
};

subtest halt => sub {
    my $r = CLASS->new(%base_args);
    is($r->halt, undef, "halt is undef initially");
    $r->set_halt('stop');
    is($r->halt, 'stop', "halt set correctly");
};

subtest no_json => sub {
    my $r = CLASS->new(%base_args);
    my @excl = $r->no_json;
    ok(scalar @excl > 0, "no_json returns a non-empty list");
    ok((grep { $_ eq 'todo'     } @excl), "todo is excluded from JSON");
    ok((grep { $_ eq 'running'  } @excl), "running is excluded from JSON");
    ok((grep { $_ eq 'complete' } @excl), "complete is excluded from JSON");
};

done_testing;
