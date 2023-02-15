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
  { data_type => "char", is_nullable => 0, size => 36 },
  "name",
  { data_type => "text", is_nullable => 0 },
  "local_file",
  { data_type => "text", is_nullable => 1 },
  "data",
  { data_type => "longblob", is_nullable => 1 },
);
__PACKAGE__->set_primary_key("log_file_id");
__PACKAGE__->has_many(
  "runs",
  "Test2::Harness::UI::Schema::Result::Run",
  { "foreign.log_file_id" => "self.log_file_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-14 17:04:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:JmvQcdeJQVS303ILPc+ITQ


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
