use Test2::V0;

use Test2::Harness2::Collector::Parser::IOParser;
use Test2::Harness2::Event;

subtest 'construction' => sub {
    my $parser = Test2::Harness2::Collector::Parser::IOParser->new(ipcm_info => {});
    ok($parser, "created parser");
};

subtest 'parse stdout' => sub {
    my $parser = Test2::Harness2::Collector::Parser::IOParser->new(ipcm_info => {});
    my $event  = $parser->parse_io(stream => 'stdout', line => 'hello');

    ok($event, "got event");
    isa_ok($event, 'Test2::Harness2::Event');

    my $fd = $event->facet_data;
    is($fd->{from_stream}{source},  'STDOUT', "source is STDOUT");
    is($fd->{from_stream}{details}, 'hello',  "details match");
    is($fd->{info}[0]{debug},       0,        "stdout not debug");
    is($fd->{info}[0]{tag},         'STDOUT', "tag matches stream");
};

subtest 'parse stderr' => sub {
    my $parser = Test2::Harness2::Collector::Parser::IOParser->new(ipcm_info => {});
    my $event  = $parser->parse_io(stream => 'stderr', line => 'err');

    my $fd = $event->facet_data;
    is($fd->{from_stream}{source}, 'STDERR', "source is STDERR");
    is($fd->{info}[0]{debug},      1,        "stderr is debug");
    is($fd->{info}[0]{tag},        'STDERR', "tag matches stream");
};

subtest 'returns undef for undef line' => sub {
    my $parser = Test2::Harness2::Collector::Parser::IOParser->new(ipcm_info => {});
    my $event  = $parser->parse_io(stream => 'stdout', line => undef);
    ok(!defined $event, "undef line returns undef");
};

subtest 'normalize_event sets harness facet' => sub {
    my $parser = Test2::Harness2::Collector::Parser::IOParser->new(ipcm_info => {});
    my $event  = $parser->parse_io(stream => 'stdout', line => 'test');

    my $h = $event->facet_data->{harness};
    ok(defined $h->{event_id}, "event_id set in harness");
    ok(defined $h->{stamp},    "stamp set in harness");
    ok(!exists $h->{run_id},   "run_id not stamped on event");
    ok(!exists $h->{job_id},   "job_id not stamped on event");
    ok(!exists $h->{job_try},  "job_try not stamped on event");
};

subtest 'set_ipcm_info stores ipcm_info' => sub {
    my $parser = Test2::Harness2::Collector::Parser::IOParser->new(ipcm_info => {});
    my $ii     = {host => 'localhost'};
    $parser->set_ipcm_info($ii);
    is($parser->ipcm_info, $ii, 'ipcm_info stored via set_ipcm_info');
};

subtest 'ipcm_info is required at construction' => sub {
    my $ok  = eval { Test2::Harness2::Collector::Parser::IOParser->new(); 1 };
    my $err = $@;
    ok(!$ok, 'croaks without ipcm_info');
    like($err, qr/ipcm_info/, 'error mentions ipcm_info');
};

subtest 'normalize_event croaks on event_id mismatch between event and io' => sub {
    my $parser = Test2::Harness2::Collector::Parser::IOParser->new(ipcm_info => {});
    my $event  = Test2::Harness2::Event->new(
        event_id   => 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',
        facet_data => {},
    );
    my $io = {stream => 'stdout', event_id => 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB'};

    my $ok  = eval { $parser->normalize_event($io, $event); 1 };
    my $err = $@;
    ok(!$ok, 'normalize_event croaks on mismatch');
    like($err, qr/event_id mismatch/, 'error mentions event_id mismatch');
};

subtest 'normalize_event accepts matching event_ids' => sub {
    my $parser = Test2::Harness2::Collector::Parser::IOParser->new(ipcm_info => {});
    my $id     = 'CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC';
    my $event  = Test2::Harness2::Event->new(event_id => $id, facet_data => {});
    my $io     = {stream => 'stdout', event_id => $id};

    ok(lives { $parser->normalize_event($io, $event) }, 'lives when ids match');
    is($event->{event_id}, $id, 'event_id preserved');
};

done_testing;
