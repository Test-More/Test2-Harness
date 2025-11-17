use strict;
use warnings;

# This test file verifies Yath handles NULL fine
# This is also useful for verifying DB's like PostgreSQL which cannot store NULL

use Test2::Bundle::Extended;

use Cpanel::JSON::XS qw/encode_json/;

isnt( "NUL\0", "NUL", "NUL\0 ain't NUL but it is ALSO \0 json:" . encode_json({"\0" => "\0", nest => encode_json({"\0" => "\0"})}) );

done_testing();
