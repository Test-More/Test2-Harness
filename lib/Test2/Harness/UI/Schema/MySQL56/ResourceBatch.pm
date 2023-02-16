use utf8;
package Test2::Harness::UI::Schema::Result::ResourceBatch;

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
__PACKAGE__->table("resource_batch");
__PACKAGE__->add_columns(
  "resource_batch_id",
  { data_type => "char", is_nullable => 0, size => 36 },
  "run_id",
  { data_type => "char", is_foreign_key => 1, is_nullable => 0, size => 36 },
  "host_id",
  { data_type => "char", is_foreign_key => 1, is_nullable => 0, size => 36 },
  "stamp",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    is_nullable => 0,
  },
);
__PACKAGE__->set_primary_key("resource_batch_id");
__PACKAGE__->belongs_to(
  "host",
  "Test2::Harness::UI::Schema::Result::Host",
  { host_id => "host_id" },
  { is_deferrable => 1, on_delete => "RESTRICT", on_update => "RESTRICT" },
);
__PACKAGE__->has_many(
  "resources",
  "Test2::Harness::UI::Schema::Result::Resource",
  { "foreign.resource_batch_id" => "self.resource_batch_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->belongs_to(
  "run",
  "Test2::Harness::UI::Schema::Result::Run",
  { run_id => "run_id" },
  { is_deferrable => 1, on_delete => "RESTRICT", on_update => "RESTRICT" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-15 17:15:55
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:rYUhzKSNZ/UtRrzIc4s1EQ


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
