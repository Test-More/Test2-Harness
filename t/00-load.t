use 5.006;
use strict;
use warnings;
use Test::More;

plan tests => 1;

BEGIN {
    use_ok( 'Test2::Harness::Renderer::JUnit' ) || print "Bail out!\n";
}

diag( "Testing Test2::Harness::Renderer::JUnit $Test2::Harness::Renderer::JUnit::VERSION, Perl $], $^X" );
