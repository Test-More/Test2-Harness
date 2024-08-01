use Test2::V0;

use Test2::Require::Module 'DBD::Pg';
use Test2::Require::Module 'DateTime::Format::Pg';

use Test2::Tools::QuickDB;

skipall_unless_can_db(driver => 'PostgreSQL');

{
    no warnings 'once';
    $main::DRIVER = 'PostgreSQL';
}

my $test = __FILE__;
$test =~ s{[^/]+$}{test.pl}g;

$test = "./$test" unless $test =~ m{^/};

note "Test: $test";
do $test;
