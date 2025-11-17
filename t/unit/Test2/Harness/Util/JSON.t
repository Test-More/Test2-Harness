use Test2::V0 -target => 'Test2::Harness::Util::JSON';

BEGIN {
    CLASS()->import(qw/decode_json_no_null encode_json encode_pretty_json decode_json/);
}

subtest decode_json_no_null => sub {
    my $json = encode_pretty_json({
        "null\0key" => "null\0\0value",
        easy        => "null\0\0value",
        nested      => {
            value => encode_json({
                "null\0key"   => "null\0\0value",
                nested_deeper => encode_json({
                    "null\0key"        => "null\0\0value",
                    nested_even_deeper => encode_json({
                        "null\0key" => "null\0\0value",
                    }),
                }),
            }),
        }
    });

    my $orig = decode_json($json);
    my $parsed = decode_json_no_null($json);
    my $pretty = encode_pretty_json($parsed);

    is($orig->{nested}, $parsed->{nested}, "Nested item not changed, everything is already escaped");
    is($orig->{easy}, "null\0\0value", "Null present in original");
    is($parsed->{easy}, "null\\u0000\\u0000value", "Null escaped in parsed");
};

done_testing;
