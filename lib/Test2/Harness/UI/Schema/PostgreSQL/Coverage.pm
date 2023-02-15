use utf8;
package Test2::Harness::UI::Schema::Result::Coverage;

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
__PACKAGE__->table("coverage");
__PACKAGE__->add_columns(
  "coverage_id",
  { data_type => "uuid", is_nullable => 0, size => 16 },
  "run_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "test_file_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "source_file_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "source_sub_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "coverage_manager_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 1, size => 16 },
  "job_key",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 1, size => 16 },
  "metadata",
  { data_type => "jsonb", is_nullable => 1 },
);
__PACKAGE__->set_primary_key("coverage_id");
__PACKAGE__->add_unique_constraint(
  "coverage_run_id_test_file_id_source_file_id_source_sub_id_key",
  ["run_id", "test_file_id", "source_file_id", "source_sub_id"],
);
__PACKAGE__->belongs_to(
  "coverage_manager",
  "Test2::Harness::UI::Schema::Result::CoverageManager",
  { coverage_manager_id => "coverage_manager_id" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "NO ACTION",
    on_update     => "NO ACTION",
  },
);
__PACKAGE__->belongs_to(
  "job_key",
  "Test2::Harness::UI::Schema::Result::Job",
  { job_key => "job_key" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "NO ACTION",
    on_update     => "NO ACTION",
  },
);
__PACKAGE__->belongs_to(
  "run",
  "Test2::Harness::UI::Schema::Result::Run",
  { run_id => "run_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);
__PACKAGE__->belongs_to(
  "source_file",
  "Test2::Harness::UI::Schema::Result::SourceFile",
  { source_file_id => "source_file_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);
__PACKAGE__->belongs_to(
  "source_sub",
  "Test2::Harness::UI::Schema::Result::SourceSub",
  { source_sub_id => "source_sub_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);
__PACKAGE__->belongs_to(
  "test_file",
  "Test2::Harness::UI::Schema::Result::TestFile",
  { test_file_id => "test_file_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-14 17:04:45
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:hKa6DiOoGP0044tEQH4KBg


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
