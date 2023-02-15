use utf8;
package Test2::Harness::UI::Schema::Result::Run;

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
__PACKAGE__->table("runs");
__PACKAGE__->add_columns(
  "run_id",
  { data_type => "char", is_nullable => 0, size => 36 },
  "user_id",
  { data_type => "char", is_foreign_key => 1, is_nullable => 0, size => 36 },
  "run_ord",
  { data_type => "bigint", is_auto_increment => 1, is_nullable => 0 },
  "status",
  {
    data_type => "enum",
    extra => {
      list => ["pending", "running", "complete", "broken", "canceled"],
    },
    is_nullable => 0,
  },
  "worker_id",
  { data_type => "text", is_nullable => 1 },
  "error",
  { data_type => "text", is_nullable => 1 },
  "project_id",
  { data_type => "char", is_foreign_key => 1, is_nullable => 0, size => 36 },
  "pinned",
  { data_type => "tinyint", default_value => 0, is_nullable => 0 },
  "has_coverage",
  { data_type => "tinyint", default_value => 0, is_nullable => 0 },
  "added",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    default_value => \"current_timestamp",
    is_nullable => 0,
  },
  "duration",
  { data_type => "text", is_nullable => 1 },
  "log_file_id",
  { data_type => "char", is_foreign_key => 1, is_nullable => 1, size => 36 },
  "mode",
  {
    data_type => "enum",
    extra => { list => ["qvfds", "qvfd", "qvf", "summary", "complete"] },
    is_nullable => 0,
  },
  "buffer",
  {
    data_type => "enum",
    default_value => "job",
    extra => { list => ["none", "diag", "job", "run"] },
    is_nullable => 0,
  },
  "passed",
  { data_type => "integer", is_nullable => 1 },
  "failed",
  { data_type => "integer", is_nullable => 1 },
  "retried",
  { data_type => "integer", is_nullable => 1 },
  "concurrency",
  { data_type => "integer", is_nullable => 1 },
  "parameters",
  { data_type => "longtext", is_nullable => 1 },
);
__PACKAGE__->set_primary_key("run_id");
__PACKAGE__->add_unique_constraint("run_ord", ["run_ord"]);
__PACKAGE__->has_many(
  "coverages",
  "Test2::Harness::UI::Schema::Result::Coverage",
  { "foreign.run_id" => "self.run_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "jobs",
  "Test2::Harness::UI::Schema::Result::Job",
  { "foreign.run_id" => "self.run_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->belongs_to(
  "log_file",
  "Test2::Harness::UI::Schema::Result::LogFile",
  { log_file_id => "log_file_id" },
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
__PACKAGE__->has_many(
  "reportings",
  "Test2::Harness::UI::Schema::Result::Reporting",
  { "foreign.run_id" => "self.run_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "resources",
  "Test2::Harness::UI::Schema::Result::Resource",
  { "foreign.run_id" => "self.run_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "run_fields",
  "Test2::Harness::UI::Schema::Result::RunField",
  { "foreign.run_id" => "self.run_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "sweeps",
  "Test2::Harness::UI::Schema::Result::Sweep",
  { "foreign.run_id" => "self.run_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->belongs_to(
  "user",
  "Test2::Harness::UI::Schema::Result::User",
  { user_id => "user_id" },
  { is_deferrable => 1, on_delete => "RESTRICT", on_update => "RESTRICT" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-14 17:04:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:2AsU4oedT2bpZNU22DIh6g


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
