use utf8;
package Test2::Harness::UI::Schema::Result::Email;

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
__PACKAGE__->table("email");
__PACKAGE__->add_columns(
  "email_id",
  { data_type => "binary", is_nullable => 0, size => 16 },
  "user_id",
  { data_type => "binary", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "local",
  { data_type => "varchar", is_nullable => 0, size => 128 },
  "domain",
  { data_type => "varchar", is_nullable => 0, size => 128 },
  "verified",
  { data_type => "tinyint", default_value => 0, is_nullable => 0 },
);
__PACKAGE__->set_primary_key("email_id");
__PACKAGE__->add_unique_constraint("local", ["local", "domain"]);
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
  { is_deferrable => 1, on_delete => "RESTRICT", on_update => "RESTRICT" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-03-02 16:05:14
use Test2::Harness::UI::UUID qw/uuid_inflate uuid_deflate/;
__PACKAGE__->inflate_column('email_id' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
__PACKAGE__->inflate_column('user_id' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
# DO NOT MODIFY ANY PART OF THIS FILE

1;
