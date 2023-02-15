use utf8;
package Test2::Harness::UI::Schema::Result::SessionHost;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';
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
  { data_type => "char", is_nullable => 0, size => 36 },
  "session_id",
  { data_type => "char", is_foreign_key => 1, is_nullable => 0, size => 36 },
  "user_id",
  { data_type => "char", is_foreign_key => 1, is_nullable => 1, size => 36 },
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


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-14 17:04:39
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:vvyIKff+tmTOodXMpGU6Zg


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
