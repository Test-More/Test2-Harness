use Test2::V0;

BEGIN {
    my $path = "$ENV{HOME}/percona/bin";
    if (-x "$path/mysqld") {
        note "Adding '$path' to \$PATH";
        $ENV{PATH} = "$path:$ENV{PATH}";
    }
}

use Test2::Require::Module 'DBD::mysql';
use Test2::Require::Module 'DateTime::Format::MySQL';

use Test2::Tools::QuickDB;

skipall_unless_can_db(driver => 'Percona');

{
    no warnings 'once';
    $main::DRIVER = 'Percona';
}

my $test = __FILE__;
$test =~ s{[^/]+$}{test.pl}g;

$test = "./$test" unless $test =~ m{^/};

note "Test: $test";
do $test;

