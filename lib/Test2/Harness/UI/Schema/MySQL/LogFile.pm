use utf8;
package Test2::Harness::UI::Schema::Result::LogFile;

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
__PACKAGE__->table("log_files");
__PACKAGE__->add_columns(
  "log_file_id",
  { data_type => "binary", is_nullable => 0, size => 16 },
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


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-03-02 16:05:14
use Test2::Harness::UI::UUID qw/uuid_inflate uuid_deflate/;
__PACKAGE__->inflate_column('log_file_id' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
# DO NOT MODIFY ANY PART OF THIS FILE

1;
