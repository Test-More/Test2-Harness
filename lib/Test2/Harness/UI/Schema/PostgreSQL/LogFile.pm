use utf8;
package Test2::Harness::UI::Schema::Result::LogFile;

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
__PACKAGE__->table("log_files");
__PACKAGE__->add_columns(
  "log_file_id",
  {
    data_type => "uuid",
    default_value => \"uuid_generate_v4()",
    is_nullable => 0,
    size => 16,
  },
  "name",
  { data_type => "text", is_nullable => 0 },
  "local_file",
  { data_type => "text", is_nullable => 1 },
  "data",
  { data_type => "bytea", is_nullable => 1 },
);
__PACKAGE__->set_primary_key("log_file_id");
__PACKAGE__->has_many(
  "runs",
  "Test2::Harness::UI::Schema::Result::Run",
  { "foreign.log_file_id" => "self.log_file_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-10-26 13:48:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:JhJh8wuiqAjS7Rqug3DSPg


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
