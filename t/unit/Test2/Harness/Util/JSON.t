use Test2::Bundle::Extended -target => 'Test2::Harness::Util::JSON';
# HARNESS-DURATION-SHORT

use ok $CLASS;

imported_ok(qw{
    JSON
    encode_json decode_json
    encode_pretty_json encode_canon_json
});

ok(JSON(), "Have JSON constant");

can_ok(JSON(), ['new'], "JSON returns a class (" . JSON() . ")");

my $struct = { a => 1, b => 2 };
for my $encode_name (qw/encode_json encode_pretty_json encode_canon_json/) {
    is(
        decode_json(__PACKAGE__->can($encode_name)->($struct)),
        $struct,
        "Round Trip $encode_name+decode"
    );

    is(
        decode_json(__PACKAGE__->can($encode_name)->(undef)),
        undef,
        "undef/null round-trip $encode_name+decode"
    );
}

done_testing;
