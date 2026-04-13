use Test2::V0;
use File::Temp qw/tempdir/;

use Test2::Harness2::Util::JSON qw/encode_json decode_json encode_pretty_json decode_json_file encode_json_file json_true json_false/;

my $tmpdir = tempdir(CLEANUP => 1);

subtest 'encode/decode roundtrip' => sub {
    my $data = {foo => 'bar', nums => [1, 2, 3]};
    my $json = encode_json($data);
    ok(defined $json, "encode_json returns string");
    like($json, qr/"foo"/, "json contains key");

    my $decoded = decode_json($json);
    is($decoded, $data, "decode matches original");
};

subtest 'encode_pretty_json' => sub {
    my $data = {a => 1, b => 2};
    my $json = encode_pretty_json($data);
    like($json, qr/\n/, "pretty json contains newlines");
};

subtest 'json booleans' => sub {
    ok(json_true, "json_true is truthy");
    ok(!json_false, "json_false is falsy");
};

subtest 'unicode handling' => sub {
    my $data = {text => "hello"};
    my $json = encode_json($data);
    my $decoded = decode_json($json);
    is($decoded->{text}, "hello", "ASCII roundtrips");
};

subtest 'decode_json_file' => sub {
    my $file = "$tmpdir/test.json";
    my $data = {foo => 'bar', n => 42};

    open(my $fh, '>', $file) or die $!;
    print $fh encode_json($data);
    close($fh);

    my $decoded = decode_json_file($file);
    is($decoded, $data, "decode_json_file reads and decodes");
    ok(-f $file, "file still exists without unlink option");

    my $decoded2 = decode_json_file($file, unlink => 1);
    is($decoded2, $data, "decode_json_file with unlink reads correctly");
    ok(!-f $file, "file was unlinked");
};

subtest 'encode_json_file' => sub {
    my $data = {key => 'value', list => [1, 2]};
    my $file = encode_json_file($data);

    ok(defined $file, "encode_json_file returns a path");
    ok(-f $file, "temp file exists");

    my $decoded = decode_json_file($file, unlink => 1);
    is($decoded, $data, "roundtrip through encode/decode_json_file");
    ok(!-f $file, "temp file cleaned up");
};

subtest 'invalid json dies' => sub {
    like(
        dies { decode_json("not json") },
        qr/.+/,
        "decode_json dies on invalid input"
    );
};

done_testing;
