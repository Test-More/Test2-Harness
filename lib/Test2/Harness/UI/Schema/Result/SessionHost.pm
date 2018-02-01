package Test2::Harness::UI::Schema::Result::SessionHost;
use strict;
use warnings;

use parent qw/DBIx::Class::Core/;

__PACKAGE__->load_components(qw/InflateColumn::DateTime Core/);

__PACKAGE__->table('session_hosts');

__PACKAGE__->add_columns(
    qw/session_host_ui_id session_ui_id address agent user_ui_id/,
    created  => {data_type => 'datetime'},
    accessed => {data_type => 'datetime'},
);

__PACKAGE__->set_primary_key('session_host_ui_id');

__PACKAGE__->belongs_to(user    => 'Test2::Harness::UI::Schema::Result::User',    'user_ui_id', {join_type => 'left'});
__PACKAGE__->belongs_to(session => 'Test2::Harness::UI::Schema::Result::Session', 'session_ui_id');

1;
