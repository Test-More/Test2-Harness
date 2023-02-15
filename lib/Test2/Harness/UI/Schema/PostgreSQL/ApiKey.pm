use utf8;
package Test2::Harness::UI::Schema::Result::ApiKey;

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
__PACKAGE__->table("api_keys");
__PACKAGE__->add_columns(
  "api_key_id",
  {
    data_type => "uuid",
    default_value => \"uuid_generate_v4()",
    is_nullable => 0,
    size => 16,
  },
  "user_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "name",
  { data_type => "varchar", is_nullable => 0, size => 128 },
  "value",
  { data_type => "varchar", is_nullable => 0, size => 36 },
  "status",
  {
    data_type => "enum",
    default_value => "active",
    extra => {
      custom_type_name => "api_key_status",
      list => ["active", "disabled", "revoked"],
    },
    is_nullable => 0,
  },
);
__PACKAGE__->set_primary_key("api_key_id");
__PACKAGE__->add_unique_constraint("api_keys_value_key", ["value"]);
__PACKAGE__->belongs_to(
  "user",
  "Test2::Harness::UI::Schema::Result::User",
  { user_id => "user_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-14 17:04:45
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:s6y66+QE6/zAdvaQ3UyRxg


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
