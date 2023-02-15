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
  {
    data_type => "uuid",
    default_value => \"uuid_generate_v4()",
    is_nullable => 0,
    size => 16,
  },
  "run_ord",
  {
    data_type         => "bigint",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "runs_run_ord_seq",
  },
  "user_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "status",
  {
    data_type => "enum",
    default_value => "pending",
    extra => {
      custom_type_name => "queue_status",
      list => ["pending", "running", "complete", "broken", "canceled"],
    },
    is_nullable => 0,
  },
  "worker_id",
  { data_type => "text", is_nullable => 1 },
  "error",
  { data_type => "text", is_nullable => 1 },
  "project_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "pinned",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
  "has_coverage",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
  "added",
  {
    data_type     => "timestamp",
    default_value => \"current_timestamp",
    is_nullable   => 0,
    original      => { default_value => \"now()" },
  },
  "duration",
  { data_type => "text", is_nullable => 1 },
  "mode",
  {
    data_type => "enum",
    default_value => "qvfd",
    extra => {
      custom_type_name => "run_modes",
      list => ["summary", "qvfds", "qvfd", "qvf", "complete"],
    },
    is_nullable => 0,
  },
  "buffer",
  {
    data_type => "enum",
    default_value => "job",
    extra => {
      custom_type_name => "run_buffering",
      list => ["none", "diag", "job", "run"],
    },
    is_nullable => 0,
  },
  "log_file_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 1, size => 16 },
  "passed",
  { data_type => "integer", is_nullable => 1 },
  "failed",
  { data_type => "integer", is_nullable => 1 },
  "retried",
  { data_type => "integer", is_nullable => 1 },
  "concurrency",
  { data_type => "integer", is_nullable => 1 },
  "parameters",
  { data_type => "jsonb", is_nullable => 1 },
);
__PACKAGE__->set_primary_key("run_id");
__PACKAGE__->add_unique_constraint("runs_run_ord_key", ["run_ord"]);
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
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "NO ACTION",
    on_update     => "NO ACTION",
  },
);
__PACKAGE__->belongs_to(
  "project",
  "Test2::Harness::UI::Schema::Result::Project",
  { project_id => "project_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
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
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-14 17:04:45
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:gGtbrXNs5hHk1Jopzk07IA


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
