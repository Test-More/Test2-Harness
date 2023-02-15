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
  { data_type => "char", is_nullable => 0, size => 36 },
  "job_key",
  { data_type => "char", is_foreign_key => 1, is_nullable => 0, size => 36 },
  "name",
  { data_type => "varchar", is_nullable => 0, size => 512 },
  "data",
  { data_type => "json", is_nullable => 1 },
  "details",
  { data_type => "text", is_nullable => 1 },
  "raw",
  { data_type => "text", is_nullable => 1 },
  "link",
  { data_type => "text", is_nullable => 1 },
);
__PACKAGE__->set_primary_key("job_field_id");
__PACKAGE__->add_unique_constraint("job_key", ["job_key", "name"]);
__PACKAGE__->belongs_to(
  "job_key",
  "Test2::Harness::UI::Schema::Result::Job",
  { job_key => "job_key" },
  { is_deferrable => 1, on_delete => "RESTRICT", on_update => "RESTRICT" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-14 17:04:39
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:2EeqDJY0kuQ41L/xMpQF5Q


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
