package Test2::Harness::Util::UUID;
use strict;
use warnings;

our $VERSION = '0.001066';

use Crypt::URandom;

use Importer 'Importer' => 'import';

our @EXPORT = qw/gen_uuid/;

sub random_uuid_binary {
    my $bytes = Crypt::URandom::urandom(16);

    # Setting these bits this way is required by RFC 4122.
    vec($bytes, 35, 2) = 0x2;
    vec($bytes, 13, 4) = 0x4;
    return $bytes;
}

sub gen_uuid() {
    return uc join '-', unpack('H8 H4 H4 H4 H12', random_uuid_binary());
}

1;
