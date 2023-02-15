use utf8;
package Test2::Harness::UI::Schema::Result::Permission;

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
__PACKAGE__->table("permissions");
__PACKAGE__->add_columns(
  "permission_id",
  {
    data_type => "uuid",
    default_value => \"uuid_generate_v4()",
    is_nullable => 0,
    size => 16,
  },
  "project_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "user_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "updated",
  {
    data_type     => "timestamp",
    default_value => \"current_timestamp",
    is_nullable   => 0,
    original      => { default_value => \"now()" },
  },
  "cpan_batch",
  { data_type => "bigint", is_nullable => 1 },
);
__PACKAGE__->set_primary_key("permission_id");
__PACKAGE__->add_unique_constraint(
  "permissions_project_id_user_id_key",
  ["project_id", "user_id"],
);
__PACKAGE__->belongs_to(
  "project",
  "Test2::Harness::UI::Schema::Result::Project",
  { project_id => "project_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);
__PACKAGE__->belongs_to(
  "user",
  "Test2::Harness::UI::Schema::Result::User",
  { user_id => "user_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-14 17:04:45
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:Q9OwUOOLFgGAkqjrhVpTLQ


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
