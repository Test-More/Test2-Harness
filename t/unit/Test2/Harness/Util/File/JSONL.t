use Test2::Bundle::Extended -target => 'Test2::Harness::Util::File::JSONL';
# HARNESS-DURATION-SHORT

use ok $CLASS;

isa_ok($CLASS, 'Test2::Harness::Util::File');
isa_ok($CLASS, 'Test2::Harness::Util::File::Stream');

is($CLASS->decode('{"a":1}'), {a => 1}, "decode will decode json");
is($CLASS->encode({}), "{}\n", "encode will encode json and append a newline");

done_testing;
