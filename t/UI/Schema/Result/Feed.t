use Test2::V0 -target => 'Test2::Harness::UI::Schema::Result::Feed';

use lib 't/lib';
use Test2::Harness::DB::Postgresql;

my $db = Test2::Harness::DB::Postgresql->new();
my $schema = $db->schema;

ok(my $feed = $schema->resultset('Feed')->find({feed_ui_id => 1}), "Found the first feed");

can_ok($feed, qw/feed_ui_id user_ui_id stamp permissions/);

ok($feed->user, "got user");

my @runs = $feed->runs->all;
is(@runs, 1, "Got 1 run");

done_testing;
