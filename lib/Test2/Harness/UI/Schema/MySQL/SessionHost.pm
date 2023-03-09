use utf8;
package Test2::Harness::UI::Schema::Result::SessionHost;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY ANY PART OF THIS FILE

use strict;
use warnings;

use base 'Test2::Harness::UI::Schema::ResultBase';
__PACKAGE__->load_components(
  "InflateColumn::DateTime",
  "InflateColumn::Serializer",
  "InflateColumn::Serializer::JSON",
  "Tree::AdjacencyList",
  "UUIDColumns",
);
__PACKAGE__->table("session_hosts");
__PACKAGE__->add_columns(
  "session_host_id",
  { data_type => "binary", is_nullable => 0, size => 16 },
  "session_id",
  { data_type => "binary", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "user_id",
  { data_type => "binary", is_foreign_key => 1, is_nullable => 1, size => 16 },
  "created",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    default_value => \"current_timestamp",
    is_nullable => 0,
  },
  "accessed",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    default_value => \"current_timestamp",
    is_nullable => 0,
  },
  "address",
  { data_type => "varchar", is_nullable => 0, size => 128 },
  "agent",
  { data_type => "varchar", is_nullable => 0, size => 128 },
);
__PACKAGE__->set_primary_key("session_host_id");
__PACKAGE__->add_unique_constraint("session_id", ["session_id", "address", "agent"]);
__PACKAGE__->belongs_to(
  "session",
  "Test2::Harness::UI::Schema::Result::Session",
  { session_id => "session_id" },
  { is_deferrable => 1, on_delete => "RESTRICT", on_update => "RESTRICT" },
);
__PACKAGE__->belongs_to(
  "user",
  "Test2::Harness::UI::Schema::Result::User",
  { user_id => "user_id" },
  {
    is_deferrable => 1,
    join_type     => "LEFT",
    on_delete     => "RESTRICT",
    on_update     => "RESTRICT",
  },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-03-02 16:05:14
use Test2::Harness::UI::UUID qw/uuid_inflate uuid_deflate/;
__PACKAGE__->inflate_column('session_host_id' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
__PACKAGE__->inflate_column('user_id' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
__PACKAGE__->inflate_column('session_id' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
# DO NOT MODIFY ANY PART OF THIS FILE

1;
