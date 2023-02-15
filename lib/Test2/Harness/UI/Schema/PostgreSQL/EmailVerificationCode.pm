use utf8;
package Test2::Harness::UI::Schema::Result::EmailVerificationCode;

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
__PACKAGE__->table("email_verification_codes");
__PACKAGE__->add_columns(
  "evcode_id",
  {
    data_type => "uuid",
    default_value => \"uuid_generate_v4()",
    is_nullable => 0,
    size => 16,
  },
  "email_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
);
__PACKAGE__->set_primary_key("evcode_id");
__PACKAGE__->add_unique_constraint("email_verification_codes_email_id_key", ["email_id"]);
__PACKAGE__->belongs_to(
  "email",
  "Test2::Harness::UI::Schema::Result::Email",
  { email_id => "email_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-14 17:04:45
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:bF/u2wSHtSnGcYsVfBGuCA


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
