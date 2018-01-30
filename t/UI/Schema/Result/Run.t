use Test2::V0 -target => 'Test2::Harness::UI::Schema::Result::Run';

use lib 't/lib';
use Test2::Harness::DB::Postgresql;

my $db = Test2::Harness::DB::Postgresql->new();
my $schema = $db->schema;

ok(my $run = $schema->resultset('Run')->find({run_ui_id => 1}), "Found the first run");

can_ok($run, qw/run_ui_id feed_ui_id facet_ui_id run_id permissions/);

ok($run->feed, "got feed");
ref_is($run->user, $run->feed->user, "got user");

ok($run->facet, "The run was created by a facet, so we get it.");

my @jobs = $run->jobs->all;
is(@jobs, 2, "simple data has 1 job, plus the 0 (internal) job");

done_testing;
