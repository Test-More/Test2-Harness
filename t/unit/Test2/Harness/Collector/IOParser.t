use Test2::V0 -target => 'Test2::Harness::Collector::IOParser';

my $CLASS = CLASS();

sub make_parser {
    return $CLASS->new(
        run_id  => 'run-1',
        job_id  => 'job-1',
        job_try => 0,
    );
}

subtest 'constructor and accessors' => sub {
    my $p = make_parser();
    ok($p, "object created");
    is($p->run_id,  'run-1', "run_id accessor");
    is($p->job_id,  'job-1', "job_id accessor");
    is($p->job_try, 0,       "job_try accessor");
};

subtest 'get_event with no event in io' => sub {
    my $p = make_parser();
    my $io = { stream => 'stdout', stamp => 1000 };
    my $event = $p->get_event($io);
    ok($event, "got an event");
    ok(ref($event) eq 'HASH', "event is a hash ref");
    ok($event->{facet_data}, "event has facet_data");
    is($event->{stamp}, 1000, "stamp taken from io");
};

subtest 'get_event with pre-built event in io' => sub {
    my $p = make_parser();
    my $pre_event = { event_id => 'e-1', stamp => 2000, facet_data => { harness => {} } };
    my $io = { stream => 'stdout', event => $pre_event };
    my $event = $p->get_event($io);
    is($event->{event_id}, 'e-1', "pre-built event returned");
    is($event->{stamp}, 2000, "pre-built event stamp preserved");
    ok(!$io->{event}, "event removed from io after retrieval");
};

subtest 'get_event with data key in io' => sub {
    my $p = make_parser();
    my $pre_event = { event_id => 'e-2', stamp => 3000, facet_data => {} };
    my $io = { stream => 'stdout', data => $pre_event };
    my $event = $p->get_event($io);
    is($event->{event_id}, 'e-2', "data event returned");
    ok(!$io->{data}, "data removed from io after retrieval");
};

subtest 'normalize_event sets run_id/job_id/job_try on event' => sub {
    my $p = make_parser();
    my $io    = { stream => 'stdout', stamp => 5000 };
    my $event = { stamp => 5000, facet_data => { harness => {} } };
    $p->normalize_event($io, $event);

    is($event->{run_id},  'run-1', "run_id set on event");
    is($event->{job_id},  'job-1', "job_id set on event");
    is($event->{job_try}, 0,       "job_try set on event");
    is($event->{facet_data}{harness}{run_id},  'run-1', "run_id set in harness facet");
    is($event->{facet_data}{harness}{job_id},  'job-1', "job_id set in harness facet");
    is($event->{facet_data}{harness}{job_try}, 0,       "job_try set in harness facet");
};

subtest 'normalize_event detects mismatch and dies' => sub {
    my $p = make_parser();
    my $io    = { stream => 'stdout' };
    my $event = {
        run_id     => 'DIFFERENT',
        facet_data => { harness => { run_id => 'run-1' } },
    };
    like(
        dies { $p->normalize_event($io, $event) },
        qr/mismatch/,
        "normalize_event dies on mismatch"
    );
};

subtest 'parse_stream_line adds from_stream and info facets' => sub {
    my $p = make_parser();
    my $io    = { stream => 'stdout', line => 'hello world', stamp => 1 };
    my $event = { stamp => 1, facet_data => { harness => {} } };
    $p->parse_stream_line($io, $event);

    ok($event->{facet_data}{from_stream}, "from_stream facet added");
    is($event->{facet_data}{from_stream}{source}, 'STDOUT', "source is STDOUT");
    is($event->{facet_data}{from_stream}{details}, 'hello world', "details is line text");

    ok($event->{facet_data}{info}, "info facet added");
    is($event->{facet_data}{info}[0]{details}, 'hello world', "info details is line text");
    ok(!$event->{facet_data}{info}[0]{debug}, "not debug for stdout");
};

subtest 'parse_stream_line marks stderr as debug' => sub {
    my $p = make_parser();
    my $io    = { stream => 'stderr', line => 'error output', stamp => 1 };
    my $event = { stamp => 1, facet_data => { harness => {} } };
    $p->parse_stream_line($io, $event);

    is($event->{facet_data}{from_stream}{source}, 'STDERR', "source is STDERR");
    ok($event->{facet_data}{info}[0]{debug}, "debug is set for stderr");
};

subtest 'parse_io without line just normalizes' => sub {
    my $p = make_parser();
    my $io = { stream => 'stdout', stamp => 9999 };
    my @events = $p->parse_io($io);
    is(scalar @events, 1, "got one event");
    my $event = $events[0];
    is($event->{run_id}, 'run-1', "run_id normalized");
};

subtest 'parse_io with a line adds stream info' => sub {
    my $p = make_parser();
    my $io = { stream => 'stdout', line => 'some line', stamp => 1 };
    my @events = $p->parse_io($io);
    is(scalar @events, 1, "got one event");
    ok($events[0]{facet_data}{from_stream}, "from_stream set");
    is($events[0]{facet_data}{from_stream}{details}, 'some line', "line captured");
};

subtest 'parse_io dies without stream' => sub {
    my $p = make_parser();
    my $io = { line => 'no stream here' };
    like(
        dies { $p->parse_io($io) },
        qr/No Stream/,
        "dies when stream missing"
    );
};

subtest 'normalize_event uses event_id from io when not in event' => sub {
    my $p = make_parser();
    my $io    = { stream => 'stdout', event_id => 'custom-id', stamp => 1 };
    my $event = { facet_data => { harness => {} } };
    $p->normalize_event($io, $event);
    is($event->{event_id}, 'custom-id', "event_id taken from io");
};

done_testing;
