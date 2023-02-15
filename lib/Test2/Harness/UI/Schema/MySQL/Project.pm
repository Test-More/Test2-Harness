use utf8;
package Test2::Harness::UI::Schema::Result::Project;

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
__PACKAGE__->table("projects");
__PACKAGE__->add_columns(
  "project_id",
  { data_type => "char", is_nullable => 0, size => 36 },
  "name",
  { data_type => "varchar", is_nullable => 0, size => 128 },
  "owner",
  { data_type => "char", is_foreign_key => 1, is_nullable => 1, size => 36 },
);
__PACKAGE__->set_primary_key("project_id");
__PACKAGE__->add_unique_constraint("name", ["name"]);
__PACKAGE__->belongs_to(
  "owner",
  "Test2::Harness::UI::Schema::Result::User",
  { user_id => "owner" },
  {
    is_deferrable => 1,
    join_type     => "LEFT",
    on_delete     => "RESTRICT",
    on_update     => "RESTRICT",
  },
);
__PACKAGE__->has_many(
  "permissions",
  "Test2::Harness::UI::Schema::Result::Permission",
  { "foreign.project_id" => "self.project_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "reportings",
  "Test2::Harness::UI::Schema::Result::Reporting",
  { "foreign.project_id" => "self.project_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "runs",
  "Test2::Harness::UI::Schema::Result::Run",
  { "foreign.project_id" => "self.project_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-14 17:04:39
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:KMlTz/MqVFRDcwCPASEyZg


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
