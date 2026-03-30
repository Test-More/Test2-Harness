use Test2::V0 -target => 'Test2::Harness::Collector::IOParser::Stream';

my $CLASS = CLASS();

subtest 'inherits from IOParser' => sub {
    ok($CLASS->isa('Test2::Harness::Collector::IOParser'), "inherits from IOParser");
};

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

subtest 'parse_stream_line parses stdout TAP ok line' => sub {
    my $p = make_parser();
    my $io    = { stream => 'stdout', line => 'ok 1 - test passes', stamp => 1 };
    my $event = { stamp => 1, facet_data => {} };
    $p->parse_stream_line($io, $event);

    ok($event->{facet_data}{assert}, "assert facet populated");
    ok($event->{facet_data}{assert}{pass}, "assertion passes");
    ok($event->{facet_data}{from_tap}, "from_tap facet set");
    is($event->{facet_data}{from_tap}{source}, 'STDOUT', "source is STDOUT");
};

subtest 'parse_stream_line parses stdout TAP not ok line' => sub {
    my $p = make_parser();
    my $io    = { stream => 'stdout', line => 'not ok 1 - test fails', stamp => 1 };
    my $event = { stamp => 1, facet_data => {} };
    $p->parse_stream_line($io, $event);

    ok($event->{facet_data}{assert}, "assert facet populated");
    ok(!$event->{facet_data}{assert}{pass}, "assertion fails");
};

subtest 'parse_stream_line falls back for non-TAP stdout line' => sub {
    my $p = make_parser();
    my $io    = { stream => 'stdout', line => 'random output', stamp => 1 };
    my $event = { stamp => 1, facet_data => { harness => {} } };
    $p->parse_stream_line($io, $event);

    # Falls back to parent which sets from_stream
    ok($event->{facet_data}{from_stream}, "from_stream set for non-TAP line");
    is($event->{facet_data}{from_stream}{source}, 'STDOUT', "source is STDOUT");
    is($event->{facet_data}{from_stream}{details}, 'random output', "details are the line");
};

subtest 'parse_stream_line parses stderr comment as diag' => sub {
    my $p = make_parser();
    my $io    = { stream => 'stderr', line => '# a diagnostic', stamp => 1 };
    my $event = { stamp => 1, facet_data => {} };
    $p->parse_stream_line($io, $event);

    ok($event->{facet_data}{from_tap}, "from_tap set for stderr comment");
    is($event->{facet_data}{from_tap}{source}, 'STDERR', "source is STDERR");
    is($event->{facet_data}{info}[-1]{tag}, 'DIAG', "tag is DIAG");
};

subtest 'parse_stream_line falls back for non-comment stderr line' => sub {
    my $p = make_parser();
    my $io    = { stream => 'stderr', line => 'some stderr text', stamp => 1 };
    my $event = { stamp => 1, facet_data => { harness => {} } };
    $p->parse_stream_line($io, $event);

    # Falls back to parent which sets from_stream
    ok($event->{facet_data}{from_stream}, "from_stream set for non-comment stderr");
    is($event->{facet_data}{from_stream}{source}, 'STDERR', "source is STDERR");
    ok($event->{facet_data}{info}[0]{debug}, "debug is set for stderr");
};

subtest 'parse_stream_line parses plan' => sub {
    my $p = make_parser();
    my $io    = { stream => 'stdout', line => '1..5', stamp => 1 };
    my $event = { stamp => 1, facet_data => {} };
    $p->parse_stream_line($io, $event);

    ok($event->{facet_data}{plan}, "plan facet populated");
    is($event->{facet_data}{plan}{count}, 5, "plan count is 5");
};

subtest 'full parse_io with TAP ok line' => sub {
    my $p = make_parser();
    my $io = { stream => 'stdout', line => 'ok 2 - another test', stamp => time() };
    my @events = $p->parse_io($io);
    is(scalar @events, 1, "got one event");
    ok($events[0]{facet_data}{assert}, "assert facet present");
    ok($events[0]{facet_data}{assert}{pass}, "assertion passes");
    is($events[0]{run_id}, 'run-1', "run_id normalized");
};

done_testing;
