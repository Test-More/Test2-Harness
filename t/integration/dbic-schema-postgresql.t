use Test2::V0;
use Test2::Tools::QuickDB;

use lib 't/lib';
use App::Yath::Test::DBIC::Schema qw/run_schema_tests/;

skipall_unless_can_db(driver => 'PostgreSQL');

run_schema_tests(driver => 'PostgreSQL');

done_testing;
