use utf8;
package Test2::Harness::UI::Schema::Result::Reporting;

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
__PACKAGE__->table("reporting");
__PACKAGE__->add_columns(
  "reporting_id",
  { data_type => "char", is_nullable => 0, size => 36 },
  "run_ord",
  { data_type => "bigint", is_nullable => 0 },
  "job_try",
  { data_type => "integer", is_nullable => 1 },
  "subtest",
  { data_type => "varchar", is_nullable => 1, size => 512 },
  "duration",
  { data_type => "double precision", is_nullable => 0 },
  "fail",
  { data_type => "smallint", default_value => 0, is_nullable => 0 },
  "pass",
  { data_type => "smallint", default_value => 0, is_nullable => 0 },
  "retry",
  { data_type => "smallint", default_value => 0, is_nullable => 0 },
  "abort",
  { data_type => "smallint", default_value => 0, is_nullable => 0 },
  "project_id",
  { data_type => "char", is_foreign_key => 1, is_nullable => 0, size => 36 },
  "run_id",
  { data_type => "char", is_foreign_key => 1, is_nullable => 0, size => 36 },
  "user_id",
  { data_type => "char", is_foreign_key => 1, is_nullable => 0, size => 36 },
  "job_key",
  { data_type => "char", is_foreign_key => 1, is_nullable => 1, size => 36 },
  "test_file_id",
  { data_type => "char", is_foreign_key => 1, is_nullable => 1, size => 36 },
  "event_id",
  { data_type => "char", is_foreign_key => 1, is_nullable => 1, size => 36 },
);
__PACKAGE__->set_primary_key("reporting_id");
__PACKAGE__->belongs_to(
  "event",
  "Test2::Harness::UI::Schema::Result::Event",
  { event_id => "event_id" },
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
  "project",
  "Test2::Harness::UI::Schema::Result::Project",
  { project_id => "project_id" },
  { is_deferrable => 1, on_delete => "RESTRICT", on_update => "RESTRICT" },
);
__PACKAGE__->belongs_to(
  "run",
  "Test2::Harness::UI::Schema::Result::Run",
  { run_id => "run_id" },
  { is_deferrable => 1, on_delete => "RESTRICT", on_update => "RESTRICT" },
);
__PACKAGE__->belongs_to(
  "test_file",
  "Test2::Harness::UI::Schema::Result::TestFile",
  { test_file_id => "test_file_id" },
  {
    is_deferrable => 1,
    join_type     => "LEFT",
    on_delete     => "RESTRICT",
    on_update     => "RESTRICT",
  },
);
__PACKAGE__->belongs_to(
  "user",
  "Test2::Harness::UI::Schema::Result::User",
  { user_id => "user_id" },
  { is_deferrable => 1, on_delete => "RESTRICT", on_update => "RESTRICT" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-14 17:04:39
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:PMrDNX62Dkv5pwjEw1k9UQ


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
