package Test2::Harness::UI::Schema::Result::Run;
use strict;
use warnings;

__PACKAGE__->table('runs');
__PACKAGE__->add_columns(qw/run_ui_id run_id/);
__PACKAGE__->add_primary_key('run_ui_id');
__PACKAGE__->has_many(jobs => 'Test2::Harness::UI::Schema::Result::Job');

1;
