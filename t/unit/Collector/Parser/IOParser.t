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
    my $parser = Test2::Harness2::Collector::Parser::IOParser->new(
        ipcm_info => {},
        run_id    => 'R1',
        job_id    => 'J1',
        job_try   => 2,
    );
    my $event = $parser->parse_io(stream => 'stdout', line => 'test');

    my $h = $event->facet_data->{harness};
    is($h->{run_id},  'R1', "run_id propagated");
    is($h->{job_id},  'J1', "job_id propagated");
    is($h->{job_try}, 2,    "job_try propagated");
    ok(defined $h->{event_id}, "event_id set in harness");
    ok(defined $h->{stamp},    "stamp set in harness");
};

subtest 'set_process_info updates run_id/job_id/job_try' => sub {
    my $parser = Test2::Harness2::Collector::Parser::IOParser->new(ipcm_info => {});
    $parser->set_process_info(run_id => 'RX', job_id => 'JX', job_try => 4);
    is($parser->run_id,  'RX', 'run_id set via set_process_info');
    is($parser->job_id,  'JX', 'job_id set via set_process_info');
    is($parser->job_try, 4,    'job_try set via set_process_info');

    # Partial update
    $parser->set_process_info(job_try => 99);
    is($parser->run_id,  'RX', 'run_id unchanged on partial update');
    is($parser->job_try, 99,   'job_try updated on partial update');
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
