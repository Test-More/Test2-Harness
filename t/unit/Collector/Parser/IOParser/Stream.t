use Test2::V0;

use Test2::Harness2::Collector::Parser::IOParser::Stream;

sub parser { Test2::Harness2::Collector::Parser::IOParser::Stream->new(ipcm_info => {}, @_) }

subtest 'construction and inheritance' => sub {
    my $p = parser();
    ok($p, "created parser");
    isa_ok($p, 'Test2::Harness2::Collector::Parser::IOParser::Stream');
    isa_ok($p, 'Test2::Harness2::Collector::Parser::IOParser');
};

subtest 'stdout TAP replaces facet_data' => sub {
    my $event = parser()->parse_io(stream => 'stdout', line => 'ok 1 - passed');
    ok($event, "got event");

    my $fd = $event->facet_data;
    ok($fd->{assert}, "assert facet present");
    is($fd->{assert}{pass},   1, "pass");
    is($fd->{assert}{number}, 1, "number");

    is($fd->{from_tap}{source},  'STDOUT',        "from_tap STDOUT");
    is($fd->{from_tap}{details}, 'ok 1 - passed', "from_tap details");

    ok(!$fd->{from_stream}, "from_stream NOT set on TAP match");
};

subtest 'stdout plan line' => sub {
    my $event = parser()->parse_io(stream => 'stdout', line => '1..2');
    my $fd    = $event->facet_data;
    is($fd->{plan}{count},      2,        "plan count");
    is($fd->{from_tap}{source}, 'STDOUT', "from_tap");
};

subtest 'stdout non-TAP falls back to from_stream' => sub {
    my $event = parser()->parse_io(stream => 'stdout', line => 'hello world');
    my $fd    = $event->facet_data;

    ok(!$fd->{assert}, "no assert");
    ok(!$fd->{plan},   "no plan");

    is($fd->{from_stream}{source},  'STDOUT',      "from_stream source");
    is($fd->{from_stream}{details}, 'hello world', "from_stream details");
    is($fd->{info}[0]{tag},         'STDOUT',      "info tag");
    is($fd->{info}[0]{debug},       0,             "not debug");
};

subtest 'stderr comment becomes DIAG' => sub {
    my $event = parser()->parse_io(stream => 'stderr', line => '# bad thing happened');
    my $fd    = $event->facet_data;

    is($fd->{from_tap}{source}, 'STDERR', "from_tap source");
    is($fd->{info}[-1]{tag},    'DIAG',   "tag DIAG");
    is($fd->{info}[-1]{debug},  1,        "debug=1");
};

subtest 'stderr non-comment falls back to from_stream' => sub {
    my $event = parser()->parse_io(stream => 'stderr', line => 'Use of uninitialized value');
    my $fd    = $event->facet_data;

    ok(!$fd->{from_tap}, "no from_tap");

    is($fd->{from_stream}{source}, 'STDERR', "from_stream source");
    is($fd->{info}[0]{tag},        'STDERR', "info tag");
    is($fd->{info}[0]{debug},      1,        "stderr marked debug");
};

subtest 'normalize_event still runs on TAP and non-TAP events' => sub {
    my $p = parser();

    my $tap_ev = $p->parse_io(stream => 'stdout', line => 'ok 1');
    ok(defined $tap_ev->facet_data->{harness}{event_id}, "TAP event has event_id");
    ok(defined $tap_ev->facet_data->{harness}{stamp},    "TAP event has stamp");
    ok(!exists $tap_ev->facet_data->{harness}{run_id}, "no run_id stamp on TAP event");

    my $raw_ev = $p->parse_io(stream => 'stdout', line => 'not tap');
    ok(defined $raw_ev->facet_data->{harness}{event_id}, "raw event has event_id");
    ok(!exists $raw_ev->facet_data->{harness}{run_id}, "no run_id stamp on raw event");
};

subtest 'returns undef for undef line' => sub {
    my $event = parser()->parse_io(stream => 'stdout', line => undef);
    ok(!defined $event, "undef line returns undef");
};

done_testing;
