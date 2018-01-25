use Test2::V0 -target => 'Test2::Harness::UI::Schema::Result::Job';

use lib 't/lib';
use Test2::Harness::DB::Postgresql;

my $db     = Test2::Harness::DB::Postgresql->new();
my $schema = $db->connect;

ok(my $job = $schema->resultset('Job')->find({job_id => 0}), "Found job (harness-id: 0)");
can_ok($job, qw/job_ui_id run_ui_id facet_ui_id job_id file permissions/);
ok($job->run, "Job belongs to a run");
ok(!$job->facet, "Job 0 does not belong to a facet");
my @events = $job->events->all;
is(@events, 1, "got an event");

ok($job = $schema->resultset('Job')->find({job_id => 1}), "Found job (harness-id: 1)");
ok($job->run, "Job belongs to a run");
ok($job->facet, "Job belonga to a facet");
@events = $job->events->all;
is(@events, 7, "got an event");

done_testing;
