use Test2::V0 -target => 'Test2::Harness::UI::Schema::Result::Event';

use lib 't/lib';
use Test2::Harness::DB::Postgresql;

my $db = Test2::Harness::DB::Postgresql->new();

my $schema = $db->connect;

ok(my $event = $schema->resultset('Event')->find({event_ui_id => 1}), "Found the first event");

can_ok($event, qw/event_ui_id job_ui_id stamp event_id stream_id/);

ok(my $job = $event->job, "Got the job");
is($job->job_ui_id, $event->job_ui_id, "Correct job");

my @facets = $event->facets->all;
is(@facets, 3, "Found 3 facets");

ref_is($event->run, $event->job->run, "Got the run");
ref_is($event->user, $event->job->run->user, "Got the user");

done_testing;
