use Test2::V0;
use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Event;

subtest 'constructor requires event_id' => sub {
    my $ok = eval { Test2::Harness2::Event->new(facet_data => {}); 1 };
    my $err = $@;
    ok(!$ok, "dies without event_id");
    like($err, qr/event_id/, "error mentions event_id");
};

subtest 'basic construction' => sub {
    my $event = Test2::Harness2::Event->new(
        event_id   => gen_uuid(),
        stamp      => 12345.678,
        facet_data => {info => [{details => 'hello'}]},
    );

    ok($event, "created event");
    is($event->stamp, 12345.678, "stamp set");
    is($event->facet_data->{info}[0]{details}, 'hello', "facet data set");
    ok(defined $event->event_id, "event_id set");
};

subtest 'defaults' => sub {
    use Time::HiRes qw/time/;
    my $before = time;
    my $event = Test2::Harness2::Event->new(event_id => gen_uuid());
    my $after = time;

    ok($event->stamp >= $before - 1 && $event->stamp <= $after + 1, "stamp defaults to approximately now");
    ref_ok($event->facet_data, 'HASH', "facet_data defaults to hashref");
};

subtest 'as_json' => sub {
    my $event = Test2::Harness2::Event->new(
        event_id   => gen_uuid(),
        stamp      => 1234,
        facet_data => {info => [{details => 'test'}]},
    );

    my $json = $event->as_json;
    ok(defined $json, "as_json returns string");
    like($json, qr/"event_id"/, "json contains event_id");
    like($json, qr/"stamp"/, "json contains stamp");

    # Cached
    my $json2 = $event->as_json;
    is($json, $json2, "as_json is cached");
};

subtest 'TO_JSON' => sub {
    my $event = Test2::Harness2::Event->new(
        event_id   => gen_uuid(),
        stamp      => 1234,
        facet_data => {info => [{details => 'test'}]},
    );

    my $hash = $event->TO_JSON;
    ref_ok($hash, 'HASH', "TO_JSON returns hashref");
    ok(!exists $hash->{json}, "json key stripped from TO_JSON");
    ok(exists $hash->{event_id}, "event_id present");
    ok(exists $hash->{facet_data}, "facet_data present");
};

done_testing;
