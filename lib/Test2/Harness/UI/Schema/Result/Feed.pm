package Test2::Harness::UI::Schema::Result::Feed;
use strict;
use warnings;

use parent qw/DBIx::Class::Core/;

__PACKAGE__->table('feeds');
__PACKAGE__->add_columns(qw/feed_ui_id user_ui_id stamp permissions api_key_ui_id/);
__PACKAGE__->set_primary_key('feed_ui_id');

__PACKAGE__->belongs_to(user    => 'Test2::Harness::UI::Schema::Result::User', 'user_ui_id');
__PACKAGE__->belongs_to(api_key => 'Test2::Harness::UI::Schema::Result::APIKey', 'api_key_ui_id');

__PACKAGE__->has_many(runs => 'Test2::Harness::UI::Schema::Result::Run', 'feed_ui_id');

1;
