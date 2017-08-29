use Test2::Bundle::Extended -target => 'Test2::Harness::Util::JSON';

use ok $CLASS;

imported_ok(qw/JSON encode_json decode_json/);

done_testing;
