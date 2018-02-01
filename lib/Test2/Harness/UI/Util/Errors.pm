package Test2::Harness::UI::Util::Errors;
use strict;
use warnings;

use Importer Importer => 'import';

our @EXPORT = qw/ERROR_404 ERROR_405/;

my $e404 = 'e404';
sub ERROR_404() { \$e404 }

my $e405 = 'e405';
sub ERROR_405() { \$e405 }

1;

