package Test2::Harness::UI::Schema::Result::Run;
use strict;
use warnings;

use parent qw/DBIx::Class::Core/;

__PACKAGE__->table('runs');
__PACKAGE__->add_columns(qw/run_ui_id run_id stream_id/);
__PACKAGE__->set_primary_key('run_ui_id');

__PACKAGE__->belongs_to(stream => 'Test2::Harness::UI::Schema::Result::Stream', 'stream_id');

__PACKAGE__->has_many(jobs => 'Test2::Harness::UI::Schema::Result::Job', 'job_ui_id');

sub user { shift->stream->user }

1;
