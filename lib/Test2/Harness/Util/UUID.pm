package Test2::Harness::Util::UUID;
use strict;
use warnings;

our $VERSION = '0.001073';

use Data::UUID;
use Importer 'Importer' => 'import';

our @EXPORT = qw/gen_uuid/;

my $UG = Data::UUID->new;
sub gen_uuid() { $UG->create_str() }

1;
