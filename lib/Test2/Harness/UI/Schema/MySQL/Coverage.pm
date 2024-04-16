use utf8;
package Test2::Harness::UI::Schema::Result::Coverage;

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
__PACKAGE__->table("coverage");
__PACKAGE__->add_columns(
  "coverage_id",
  { data_type => "binary", is_nullable => 0, size => 16 },
  "run_id",
  { data_type => "binary", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "test_file_id",
  { data_type => "binary", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "source_file_id",
  { data_type => "binary", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "source_sub_id",
  { data_type => "binary", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "coverage_manager_id",
  { data_type => "binary", is_foreign_key => 1, is_nullable => 1, size => 16 },
  "job_key",
  { data_type => "binary", is_foreign_key => 1, is_nullable => 1, size => 16 },
  "metadata",
  { data_type => "json", is_nullable => 1 },
);
__PACKAGE__->set_primary_key("coverage_id");
__PACKAGE__->add_unique_constraint(
  "run_id",
  ["run_id", "test_file_id", "source_file_id", "source_sub_id"],
);
__PACKAGE__->belongs_to(
  "coverage_manager",
  "Test2::Harness::UI::Schema::Result::CoverageManager",
  { coverage_manager_id => "coverage_manager_id" },
  {
    is_deferrable => 1,
    join_type     => "LEFT",
    on_delete     => "RESTRICT",
    on_update     => "RESTRICT",
  },
);
__PACKAGE__->belongs_to(
  "job_key",
  "Test2::Harness::UI::Schema::Result::Job",
  { job_key => "job_key" },
  {
    is_deferrable => 1,
    join_type     => "LEFT",
    on_delete     => "RESTRICT",
    on_update     => "RESTRICT",
  },
);
__PACKAGE__->belongs_to(
  "run",
  "Test2::Harness::UI::Schema::Result::Run",
  { run_id => "run_id" },
  { is_deferrable => 1, on_delete => "RESTRICT", on_update => "RESTRICT" },
);
__PACKAGE__->belongs_to(
  "source_file",
  "Test2::Harness::UI::Schema::Result::SourceFile",
  { source_file_id => "source_file_id" },
  { is_deferrable => 1, on_delete => "RESTRICT", on_update => "RESTRICT" },
);
__PACKAGE__->belongs_to(
  "source_sub",
  "Test2::Harness::UI::Schema::Result::SourceSub",
  { source_sub_id => "source_sub_id" },
  { is_deferrable => 1, on_delete => "RESTRICT", on_update => "RESTRICT" },
);
__PACKAGE__->belongs_to(
  "test_file",
  "Test2::Harness::UI::Schema::Result::TestFile",
  { test_file_id => "test_file_id" },
  { is_deferrable => 1, on_delete => "RESTRICT", on_update => "RESTRICT" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-03-02 16:05:14
use Test2::Harness::UI::UUID qw/uuid_inflate uuid_deflate/;
__PACKAGE__->inflate_column('source_sub_id' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
__PACKAGE__->inflate_column('coverage_id' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
__PACKAGE__->inflate_column('coverage_manager_id' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
__PACKAGE__->inflate_column('test_file_id' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
__PACKAGE__->inflate_column('run_id' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
__PACKAGE__->inflate_column('job_key' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
__PACKAGE__->inflate_column('source_file_id' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
# DO NOT MODIFY ANY PART OF THIS FILE

1;
