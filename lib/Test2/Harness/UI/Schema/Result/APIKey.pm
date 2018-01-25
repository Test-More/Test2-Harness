package Test2::Harness::UI::Schema::Result::APIKey;
use strict;
use warnings;

use parent qw/DBIx::Class::Core/;

__PACKAGE__->table('api_keys');
__PACKAGE__->add_columns(qw/api_key_ui_id user_ui_id name value status/);
__PACKAGE__->set_primary_key('api_key_ui_id');

__PACKAGE__->belongs_to(user    => 'Test2::Harness::UI::Schema::Result::User', 'user_ui_id');

__PACKAGE__->has_many(feeds => 'Test2::Harness::UI::Schema::Result::Feed', 'api_key_ui_id');

1;
