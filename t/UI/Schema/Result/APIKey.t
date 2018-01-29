use Test2::V0 -target => 'Test2::Harness::UI::Schema::Result::APIKey';

use lib 't/lib';
use Test2::Harness::DB::Postgresql;

my $db = Test2::Harness::DB::Postgresql->new();
my $schema = $db->connect;

ok(my $key = $schema->resultset('APIKey')->find({api_key_ui_id => 1}), "Found the first key");

can_ok($key, qw/api_key_ui_id user_ui_id name value status/);

ok($key->user, "got user");

my @feeds = $key->feeds->all;
is(@feeds, 1, "Got 1 feed");

done_testing;
