use Test2::V0;

use Test2::Require::Module 'DBD::mysql';
use Test2::Require::Module 'DateTime::Format::MySQL';

use Test2::Tools::QuickDB;

skipall_unless_can_db(driver => 'MySQL');

{
    no warnings 'once';
    $main::DRIVER = 'MySQL';
}

my $test = __FILE__;
$test =~ s{[^/]+$}{test.pl}g;

$test = "./$test" unless $test =~ m{^/};

note "Test: $test";
do $test;

