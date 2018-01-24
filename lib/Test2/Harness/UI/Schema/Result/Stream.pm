package Test2::Harness::UI::Schema::Result::Stream;
use strict;
use warnings;

use parent qw/DBIx::Class::Core/;

__PACKAGE__->table('streams');
__PACKAGE__->add_columns(qw/stream_id user_id/);
__PACKAGE__->set_primary_key('stream_id');

__PACKAGE__->belongs_to(user => 'Test2::Harness::UI::Schema::Result::User', 'user_id');

__PACKAGE__->has_many(runs => 'Test2::Harness::UI::Schema::Result::Run', 'run_ui_id');

1;
