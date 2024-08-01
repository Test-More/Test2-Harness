use Test2::V0;

use Test2::Require::Module 'DBD::SQLite';
use Test2::Require::Module 'DateTime::Format::SQLite';

use Test2::Tools::QuickDB;

skipall_unless_can_db(driver => 'SQLite');

{
    no warnings 'once';
    $main::DRIVER = 'SQLite';
}

my $test = __FILE__;
$test =~ s{[^/]+$}{test.pl}g;

$test = "./$test" unless $test =~ m{^/};

note "Test: $test";
do $test;
