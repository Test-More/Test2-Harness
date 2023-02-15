use utf8;
package Test2::Harness::UI::Schema::Result::JobField;

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
__PACKAGE__->table("job_fields");
__PACKAGE__->add_columns(
  "job_field_id",
  { data_type => "uuid", is_nullable => 0, size => 16 },
  "job_key",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "name",
  { data_type => "varchar", is_nullable => 0, size => 512 },
  "data",
  { data_type => "jsonb", is_nullable => 1 },
  "details",
  { data_type => "text", is_nullable => 1 },
  "raw",
  { data_type => "text", is_nullable => 1 },
  "link",
  { data_type => "text", is_nullable => 1 },
);
__PACKAGE__->set_primary_key("job_field_id");
__PACKAGE__->add_unique_constraint("job_fields_job_key_name_key", ["job_key", "name"]);
__PACKAGE__->belongs_to(
  "job_key",
  "Test2::Harness::UI::Schema::Result::Job",
  { job_key => "job_key" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-14 17:04:45
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:UfJSCokuOOuiHe8xADLTeg


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
