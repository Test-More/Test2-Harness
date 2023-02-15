use utf8;
package Test2::Harness::UI::Schema::Result::Email;

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
__PACKAGE__->table("email");
__PACKAGE__->add_columns(
  "email_id",
  {
    data_type => "uuid",
    default_value => \"uuid_generate_v4()",
    is_nullable => 0,
    size => 16,
  },
  "user_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "local",
  { data_type => "citext", is_nullable => 0 },
  "domain",
  { data_type => "citext", is_nullable => 0 },
  "verified",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
);
__PACKAGE__->set_primary_key("email_id");
__PACKAGE__->add_unique_constraint("email_local_domain_key", ["local", "domain"]);
__PACKAGE__->might_have(
  "email_verification_code",
  "Test2::Harness::UI::Schema::Result::EmailVerificationCode",
  { "foreign.email_id" => "self.email_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->might_have(
  "primary_email",
  "Test2::Harness::UI::Schema::Result::PrimaryEmail",
  { "foreign.email_id" => "self.email_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->belongs_to(
  "user",
  "Test2::Harness::UI::Schema::Result::User",
  { user_id => "user_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-14 17:04:45
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:nPVm5PseUFe9W2QwimnEQw


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
