use utf8;
package Test2::Harness::UI::Schema::Result::PrimaryEmail;

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
__PACKAGE__->table("primary_email");
__PACKAGE__->add_columns(
  "user_id",
  { data_type => "char", is_foreign_key => 1, is_nullable => 0, size => 36 },
  "email_id",
  { data_type => "char", is_foreign_key => 1, is_nullable => 0, size => 36 },
);
__PACKAGE__->set_primary_key("user_id");
__PACKAGE__->add_unique_constraint("email_id", ["email_id"]);
__PACKAGE__->belongs_to(
  "email",
  "Test2::Harness::UI::Schema::Result::Email",
  { email_id => "email_id" },
  { is_deferrable => 1, on_delete => "RESTRICT", on_update => "RESTRICT" },
);
__PACKAGE__->belongs_to(
  "user",
  "Test2::Harness::UI::Schema::Result::User",
  { user_id => "user_id" },
  { is_deferrable => 1, on_delete => "RESTRICT", on_update => "RESTRICT" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-14 17:04:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:ybl/VC6/PTU8MLma6c6nVA


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
