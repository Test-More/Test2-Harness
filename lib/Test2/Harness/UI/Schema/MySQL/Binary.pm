use utf8;
package Test2::Harness::UI::Schema::Result::Binary;

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
__PACKAGE__->table("binaries");
__PACKAGE__->add_columns(
  "binary_id",
  { data_type => "char", is_nullable => 0, size => 36 },
  "event_id",
  { data_type => "char", is_foreign_key => 1, is_nullable => 0, size => 36 },
  "filename",
  { data_type => "varchar", is_nullable => 0, size => 512 },
  "description",
  { data_type => "text", is_nullable => 1 },
  "is_image",
  { data_type => "tinyint", default_value => 0, is_nullable => 0 },
  "data",
  { data_type => "longblob", is_nullable => 0 },
);
__PACKAGE__->set_primary_key("binary_id");
__PACKAGE__->belongs_to(
  "event",
  "Test2::Harness::UI::Schema::Result::Event",
  { event_id => "event_id" },
  { is_deferrable => 1, on_delete => "RESTRICT", on_update => "RESTRICT" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-14 17:04:39
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:VFLKLHuX3hVt7z3cub+Gnw


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
