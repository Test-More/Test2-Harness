use Test2::V0 -target => 'Test2::Harness::UI::Schema::Result::Feed';

use lib 't/lib';
use Test2::Harness::DB::Postgresql;

my $db = Test2::Harness::DB::Postgresql->new();
my $schema = $db->connect;
