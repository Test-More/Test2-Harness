use utf8;
package Test2::Harness::UI::Schema::Result::ApiKey;

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
__PACKAGE__->table("api_keys");
__PACKAGE__->add_columns(
  "api_key_id",
  { data_type => "binary", is_nullable => 0, size => 16 },
  "user_id",
  { data_type => "binary", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "name",
  { data_type => "varchar", is_nullable => 0, size => 128 },
  "value",
  { data_type => "varchar", is_nullable => 0, size => 16 },
  "status",
  {
    data_type => "enum",
    extra => { list => ["active", "disabled", "revoked"] },
    is_nullable => 0,
  },
);
__PACKAGE__->set_primary_key("api_key_id");
__PACKAGE__->add_unique_constraint("value", ["value"]);
__PACKAGE__->belongs_to(
  "user",
  "Test2::Harness::UI::Schema::Result::User",
  { user_id => "user_id" },
  { is_deferrable => 1, on_delete => "RESTRICT", on_update => "RESTRICT" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-03-02 16:05:19
use Test2::Harness::UI::UUID qw/uuid_inflate uuid_deflate/;
__PACKAGE__->inflate_column('api_key_id' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
__PACKAGE__->inflate_column('user_id' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
# DO NOT MODIFY ANY PART OF THIS FILE

1;
