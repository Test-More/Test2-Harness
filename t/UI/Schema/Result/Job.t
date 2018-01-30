use Test2::V0 -target => 'Test2::Harness::UI::Schema::Result::Job';

use lib 't/lib';
use Test2::Harness::DB::Postgresql;

my $db     = Test2::Harness::DB::Postgresql->new();
my $schema = $db->schema;

ok(my $job = $schema->resultset('Job')->find({job_id => 0}), "Found job (harness-id: 0)");
can_ok($job, qw/job_ui_id run_ui_id job_facet_ui_id end_facet_ui_id job_id file permissions/);
ok($job->run, "Job belongs to a run");
ok(!$job->end_facet, "Job 0 does not belong to an end facet");
ok(!$job->job_facet, "Job 0 does not belong to a job facet");
my @events = $job->events->all;
is(@events, 1, "got an event");

ok($job = $schema->resultset('Job')->find({job_id => 1}), "Found job (harness-id: 1)");
ok($job->run, "Job belongs to a run");
ok($job->job_facet, "Job belonga to a job facet");
ok($job->end_facet, "Job belonga to an end facet");
@events = $job->events->all;
is(@events, 7, "got an event");

done_testing;
