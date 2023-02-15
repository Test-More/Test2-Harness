use utf8;
package Test2::Harness::UI::Schema::Result::User;

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
__PACKAGE__->table("users");
__PACKAGE__->add_columns(
  "user_id",
  { data_type => "char", is_nullable => 0, size => 36 },
  "username",
  { data_type => "varchar", is_nullable => 0, size => 64 },
  "pw_hash",
  { data_type => "varchar", is_nullable => 1, size => 31 },
  "pw_salt",
  { data_type => "varchar", is_nullable => 1, size => 22 },
  "realname",
  { data_type => "varchar", is_nullable => 1, size => 64 },
  "role",
  {
    data_type => "enum",
    extra => { list => ["admin", "user"] },
    is_nullable => 0,
  },
);
__PACKAGE__->set_primary_key("user_id");
__PACKAGE__->add_unique_constraint("username", ["username"]);
__PACKAGE__->has_many(
  "api_keys",
  "Test2::Harness::UI::Schema::Result::ApiKey",
  { "foreign.user_id" => "self.user_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "emails",
  "Test2::Harness::UI::Schema::Result::Email",
  { "foreign.user_id" => "self.user_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "permissions",
  "Test2::Harness::UI::Schema::Result::Permission",
  { "foreign.user_id" => "self.user_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->might_have(
  "primary_email",
  "Test2::Harness::UI::Schema::Result::PrimaryEmail",
  { "foreign.user_id" => "self.user_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "projects",
  "Test2::Harness::UI::Schema::Result::Project",
  { "foreign.owner" => "self.user_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "reportings",
  "Test2::Harness::UI::Schema::Result::Reporting",
  { "foreign.user_id" => "self.user_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "runs",
  "Test2::Harness::UI::Schema::Result::Run",
  { "foreign.user_id" => "self.user_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "session_hosts",
  "Test2::Harness::UI::Schema::Result::SessionHost",
  { "foreign.user_id" => "self.user_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-14 17:04:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:C4e+snew0L6XR497IBlElQ


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
