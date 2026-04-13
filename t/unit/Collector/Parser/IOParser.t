use Test2::V0;

use Test2::Harness2::Collector::Parser::IOParser;

subtest 'construction' => sub {
    my $parser = Test2::Harness2::Collector::Parser::IOParser->new();
    ok($parser, "created parser");
};

subtest 'parse stdout' => sub {
    my $parser = Test2::Harness2::Collector::Parser::IOParser->new();
    my $event  = $parser->parse_io(stream => 'stdout', line => 'hello');

    ok($event, "got event");
    isa_ok($event, 'Test2::Harness2::Event');

    my $fd = $event->facet_data;
    is($fd->{from_stream}{source}, 'STDOUT', "source is STDOUT");
    is($fd->{from_stream}{details}, 'hello', "details match");
    is($fd->{info}[0]{debug}, 0, "stdout not debug");
    is($fd->{info}[0]{tag}, 'STDOUT', "tag matches stream");
};

subtest 'parse stderr' => sub {
    my $parser = Test2::Harness2::Collector::Parser::IOParser->new();
    my $event  = $parser->parse_io(stream => 'stderr', line => 'err');

    my $fd = $event->facet_data;
    is($fd->{from_stream}{source}, 'STDERR', "source is STDERR");
    is($fd->{info}[0]{debug}, 1, "stderr is debug");
    is($fd->{info}[0]{tag}, 'STDERR', "tag matches stream");
};

subtest 'returns undef for undef line' => sub {
    my $parser = Test2::Harness2::Collector::Parser::IOParser->new();
    my $event  = $parser->parse_io(stream => 'stdout', line => undef);
    ok(!defined $event, "undef line returns undef");
};

subtest 'normalize_event sets harness facet' => sub {
    my $parser = Test2::Harness2::Collector::Parser::IOParser->new(
        run_id  => 'R1',
        job_id  => 'J1',
        job_try => 2,
    );
    my $event = $parser->parse_io(stream => 'stdout', line => 'test');

    my $h = $event->facet_data->{harness};
    is($h->{run_id}, 'R1', "run_id propagated");
    is($h->{job_id}, 'J1', "job_id propagated");
    is($h->{job_try}, 2, "job_try propagated");
    ok(defined $h->{event_id}, "event_id set in harness");
    ok(defined $h->{stamp}, "stamp set in harness");
};

done_testing;
