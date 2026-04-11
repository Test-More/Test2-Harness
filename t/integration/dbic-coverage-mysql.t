use Test2::V0;
use Test2::Tools::QuickDB;

use lib 't/lib';
use App::Yath::Test::DBIC::Coverage qw/run_coverage_tests/;

skipall_unless_can_db(driver => 'MySQL');

run_coverage_tests(driver => 'MySQL');

done_testing;
