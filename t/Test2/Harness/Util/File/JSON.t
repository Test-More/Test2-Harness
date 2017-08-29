use Test2::Bundle::Extended -target => 'Test2::Harness::Util::File::JSON';

use ok $CLASS;

isa_ok($CLASS, 'Test2::Harness::Util::File');

my $one = $CLASS->new(name => 'fake');

is($one->decode('{"a":1}'), {a => 1}, "decode will decode json");
is($one->encode({}), "{}", "encode will encode json");

like(
    dies { $one->reset },
    qr/line reading is disabled for json files/,
    "Got expected exception for reset()"
);

like(
    dies { $one->read_line },
    qr/line reading is disabled for json files/,
    "Got expected exception for read_line()"
);

done_testing;
