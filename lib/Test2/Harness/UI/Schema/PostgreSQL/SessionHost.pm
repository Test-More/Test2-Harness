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
  {
    data_type => "uuid",
    default_value => \"uuid_generate_v4()",
    is_nullable => 0,
    size => 16,
  },
  "session_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "user_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 1, size => 16 },
  "created",
  {
    data_type     => "timestamp",
    default_value => \"current_timestamp",
    is_nullable   => 0,
    original      => { default_value => \"now()" },
  },
  "accessed",
  {
    data_type     => "timestamp",
    default_value => \"current_timestamp",
    is_nullable   => 0,
    original      => { default_value => \"now()" },
  },
  "address",
  { data_type => "text", is_nullable => 0 },
  "agent",
  { data_type => "text", is_nullable => 0 },
);
__PACKAGE__->set_primary_key("session_host_id");
__PACKAGE__->add_unique_constraint(
  "session_hosts_session_id_address_agent_key",
  ["session_id", "address", "agent"],
);
__PACKAGE__->belongs_to(
  "session",
  "Test2::Harness::UI::Schema::Result::Session",
  { session_id => "session_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);
__PACKAGE__->belongs_to(
  "user",
  "Test2::Harness::UI::Schema::Result::User",
  { user_id => "user_id" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "NO ACTION",
    on_update     => "NO ACTION",
  },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-14 17:04:45
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:je35soEAp2smQE//aqua6Q


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
