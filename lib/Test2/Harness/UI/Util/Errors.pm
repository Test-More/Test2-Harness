package Test2::Harness::UI::Util::Errors;
use strict;
use warnings;

our $VERSION = '0.000001';

use Scalar::Util qw/blessed/;

use Importer Importer => 'import';

our @EXPORT = qw/is_error_code/;

sub is_error_code {
    my $thing = shift;
    return undef unless blessed($thing);
    return undef unless $thing->isa(__PACKAGE__);
    return $$thing;
}

for my $code (400 .. 405) {
    my $val = 0 + $code;
    my $ref = bless \$val, __PACKAGE__;
    my $name = "ERROR_$code";
    push @EXPORT => $name;

    no strict 'refs';
    *{$name} = sub() { $ref };
}

sub code { ${$_[0]} }

1;
