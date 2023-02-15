use utf8;
package Test2::Harness::UI::Schema::Result::Sweep;

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
__PACKAGE__->table("sweeps");
__PACKAGE__->add_columns(
  "sweep_id",
  { data_type => "char", is_nullable => 0, size => 36 },
  "run_id",
  { data_type => "char", is_foreign_key => 1, is_nullable => 0, size => 36 },
  "name",
  { data_type => "varchar", is_nullable => 0, size => 255 },
);
__PACKAGE__->set_primary_key("sweep_id");
__PACKAGE__->add_unique_constraint("run_id", ["run_id", "name"]);
__PACKAGE__->belongs_to(
  "run",
  "Test2::Harness::UI::Schema::Result::Run",
  { run_id => "run_id" },
  { is_deferrable => 1, on_delete => "RESTRICT", on_update => "RESTRICT" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-14 17:04:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:1MqU9kLLjq+HDNdcig3dSA


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
