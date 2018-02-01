package Test2::Harness::UI::Schema::Result::Session;
use strict;
use warnings;

use parent qw/DBIx::Class::Core/;

__PACKAGE__->table('sessions');

__PACKAGE__->add_columns(qw/session_ui_id session_id active/);

__PACKAGE__->set_primary_key('session_ui_id');

__PACKAGE__->has_many(hosts => 'Test2::Harness::UI::Schema::Result::SessionHost', 'session_ui_id');

1;
