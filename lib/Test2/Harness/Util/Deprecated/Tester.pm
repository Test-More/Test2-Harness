package Test2::Harness::Util::Deprecated::Tester;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Harness::Util qw/mod2file/;
use Test2::Tools::Basic qw/ok done_testing/;
use Test2::API qw/context/;

use Test2::Harness::Util::Deprecated();

sub import {
    my $class = shift;
    my ($test_class) = @_;

    my $ctx = context();

    my @out;
    my $ok = eval {
        local $SIG{__WARN__} = sub { push @out => @_ };
        require(mod2file($test_class));
        1;
    };
    unshift @out => $@ unless $ok;

    if (grep { m/Module '$test_class' has been deprecated/ } @out) {
        $ctx->pass("Module '$test_class' is properly deprecated")
    }
    else {
        $ctx->fail("Module '$test_class' is properly deprecated")
    }

    $ctx->done_testing;

    $ctx->release;

    return;
}

1;
