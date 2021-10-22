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
  {
    data_type => "uuid",
    default_value => \"uuid_generate_v4()",
    is_nullable => 0,
    size => 16,
  },
  "name",
  { data_type => "citext", is_nullable => 0 },
);
__PACKAGE__->set_primary_key("project_id");
__PACKAGE__->add_unique_constraint("projects_name_key", ["name"]);
__PACKAGE__->has_many(
  "permissions",
  "Test2::Harness::UI::Schema::Result::Permission",
  { "foreign.project_id" => "self.project_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "runs",
  "Test2::Harness::UI::Schema::Result::Run",
  { "foreign.project_id" => "self.project_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-10-22 09:15:54
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:V+ZT40JCltQ3ZnZyKy+OuQ


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
