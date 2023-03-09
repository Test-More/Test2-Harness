use utf8;
package Test2::Harness::UI::Schema::Result::RunField;

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
__PACKAGE__->table("run_fields");
__PACKAGE__->add_columns(
  "run_field_id",
  { data_type => "uuid", is_nullable => 0, size => 16 },
  "run_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "name",
  { data_type => "varchar", is_nullable => 0, size => 255 },
  "data",
  { data_type => "jsonb", is_nullable => 1 },
  "details",
  { data_type => "text", is_nullable => 1 },
  "raw",
  { data_type => "text", is_nullable => 1 },
  "link",
  { data_type => "text", is_nullable => 1 },
);
__PACKAGE__->set_primary_key("run_field_id");
__PACKAGE__->add_unique_constraint("run_fields_run_id_name_key", ["run_id", "name"]);
__PACKAGE__->belongs_to(
  "run",
  "Test2::Harness::UI::Schema::Result::Run",
  { run_id => "run_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-03-02 16:05:20
# DO NOT MODIFY ANY PART OF THIS FILE

1;
