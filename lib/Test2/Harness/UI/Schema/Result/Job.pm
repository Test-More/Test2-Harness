package Test2::Harness::UI::Schema::Result::Job;
use strict;
use warnings;

__PACKAGE__->table('jobs');
__PACKAGE__->add_columns(qw/job_ui_id run_ui_id job_id/);
__PACKAGE__->add_primary_key('job_ui_id');
__PACKAGE__->has_many(events => 'Test2::Harness::UI::Schema::Result::Event');
__PACKAGE__->belongs_to(run => 'Test2::Harness::UI::Schema::Result::Run' . 'run_ui_id');

1;
