use 5.010000;
use strict;
use warnings;
use Test::More;

plan tests => 1;

BEGIN {
    use_ok('App::Yath::Renderer::JUnit') || print "Bail out!\n";
}

diag("Testing App::Yath::Renderer::JUnit $App::Yath::Renderer::JUnit::VERSION, Perl $], $^X");
