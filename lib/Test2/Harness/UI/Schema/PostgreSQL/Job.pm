use utf8;
package Test2::Harness::UI::Schema::Result::Job;

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
__PACKAGE__->table("jobs");
__PACKAGE__->add_columns(
  "job_key",
  { data_type => "uuid", is_nullable => 0, size => 16 },
  "job_id",
  { data_type => "uuid", is_nullable => 0, size => 16 },
  "job_try",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "job_ord",
  { data_type => "bigint", is_nullable => 0 },
  "run_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "is_harness_out",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
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
  "parameters",
  { data_type => "jsonb", is_nullable => 1 },
  "test_file_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 1, size => 16 },
  "name",
  { data_type => "text", is_nullable => 1 },
  "fail",
  { data_type => "boolean", is_nullable => 1 },
  "retry",
  { data_type => "boolean", is_nullable => 1 },
  "exit_code",
  { data_type => "integer", is_nullable => 1 },
  "launch",
  { data_type => "timestamp", is_nullable => 1 },
  "start",
  { data_type => "timestamp", is_nullable => 1 },
  "ended",
  { data_type => "timestamp", is_nullable => 1 },
  "duration",
  { data_type => "double precision", is_nullable => 1 },
  "pass_count",
  { data_type => "bigint", is_nullable => 1 },
  "fail_count",
  { data_type => "bigint", is_nullable => 1 },
  "stdout",
  { data_type => "text", is_nullable => 1 },
  "stderr",
  { data_type => "text", is_nullable => 1 },
);
__PACKAGE__->set_primary_key("job_key");
__PACKAGE__->add_unique_constraint("jobs_job_id_job_try_key", ["job_id", "job_try"]);
__PACKAGE__->has_many(
  "coverages",
  "Test2::Harness::UI::Schema::Result::Coverage",
  { "foreign.job_key" => "self.job_key" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "events",
  "Test2::Harness::UI::Schema::Result::Event",
  { "foreign.job_key" => "self.job_key" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "job_fields",
  "Test2::Harness::UI::Schema::Result::JobField",
  { "foreign.job_key" => "self.job_key" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "reportings",
  "Test2::Harness::UI::Schema::Result::Reporting",
  { "foreign.job_key" => "self.job_key" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->belongs_to(
  "run",
  "Test2::Harness::UI::Schema::Result::Run",
  { run_id => "run_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);
__PACKAGE__->belongs_to(
  "test_file",
  "Test2::Harness::UI::Schema::Result::TestFile",
  { test_file_id => "test_file_id" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "NO ACTION",
    on_update     => "NO ACTION",
  },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-14 17:04:45
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:4+xCFqrW/72uQmooiNZSgg


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
