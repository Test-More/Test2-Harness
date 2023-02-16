use utf8;
package Test2::Harness::UI::Schema::Result::Resource;

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
__PACKAGE__->table("resources");
__PACKAGE__->add_columns(
  "resource_id",
  {
    data_type => "uuid",
    default_value => \"uuid_generate_v4()",
    is_nullable => 0,
    size => 16,
  },
  "resource_batch_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "batch_ord",
  { data_type => "integer", is_nullable => 0 },
  "module",
  { data_type => "varchar", is_nullable => 0, size => 512 },
  "data",
  { data_type => "jsonb", is_nullable => 0 },
);
__PACKAGE__->set_primary_key("resource_id");
__PACKAGE__->add_unique_constraint(
  "resources_resource_batch_id_batch_ord_key",
  ["resource_batch_id", "batch_ord"],
);
__PACKAGE__->belongs_to(
  "resource_batch",
  "Test2::Harness::UI::Schema::Result::ResourceBatch",
  { resource_batch_id => "resource_batch_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-15 17:15:56
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:NLjcI8OTndKAtI7jzowKVg


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
