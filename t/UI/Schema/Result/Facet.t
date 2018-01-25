use Test2::V0 -target => 'Test2::Harness::UI::Schema::Result::Facet';

use lib 't/lib';
use Test2::Harness::DB::Postgresql;

my $db     = Test2::Harness::DB::Postgresql->new();
my $schema = $db->connect;

ok(my $facet = $schema->resultset('Facet')->find({facet_type => 'harness_run'}), "Found a run facet");

can_ok($facet, qw/facet_ui_id event_ui_id facet_type facet_name facet_value/);

ok($facet->event, "Facet belongs to an event");
ok($facet->run,   "This facet defines a run");
ok(!$facet->job,  "This facet does not define a job");

ok($facet = $schema->resultset('Facet')->find({facet_type => 'harness_job'}), "Found a job facet");
ok($facet->event, "Facet belongs to an event");
ok(!$facet->run,  "This facet does not define a run");
ok($facet->job,   "This facet does define a job");

ok($facet = $schema->resultset('Facet')->find({facet_type => 'assert'}), "Found an assert facet");
ok($facet->event, "Facet belongs to an event");
ok(!$facet->run,  "This facet does not define a run");
ok(!$facet->job,  "This facet does define a job");

subtest types => sub {
    my $facet = $schema->resultset('Facet')->create({facet_name => 'foo', event_ui_id => 1, facet_value => '{"a":"b"}'});
    is($facet->facet_type, 'other', "Set other facet type");

    my @types = qw{
        other about amnesty assert control error info meta parent plan trace
        harness harness_run harness_job harness_job_launch harness_job_start
        harness_job_exit harness_job_end
    };

    for my $type (@types) {
        $facet = $schema->resultset('Facet')->create({facet_name => $type, event_ui_id => 1, facet_value => '{"a":"b"}'});
        is($facet->facet_type, $type, "Set '$type' facet type from name");
    }
};

done_testing;
