use utf8;
package Test2::Harness::UI::Schema::Result::Binary;

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
__PACKAGE__->table("binaries");
__PACKAGE__->add_columns(
  "binary_id",
  { data_type => "binary", is_nullable => 0, size => 16 },
  "event_id",
  { data_type => "binary", is_foreign_key => 1, is_nullable => 0, size => 16 },
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


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-03-02 16:05:14
use Test2::Harness::UI::UUID qw/uuid_inflate uuid_deflate/;
__PACKAGE__->inflate_column('event_id' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
__PACKAGE__->inflate_column('binary_id' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
# DO NOT MODIFY ANY PART OF THIS FILE

1;
