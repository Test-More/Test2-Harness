use utf8;
package Test2::Harness::UI::Schema::Result::Job;

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
__PACKAGE__->table("jobs");
__PACKAGE__->add_columns(
  "job_key",
  { data_type => "binary", is_nullable => 0, size => 16 },
  "job_id",
  { data_type => "binary", is_nullable => 0, size => 16 },
  "job_try",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "job_ord",
  { data_type => "bigint", is_nullable => 0 },
  "run_id",
  { data_type => "binary", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "is_harness_out",
  { data_type => "tinyint", default_value => 0, is_nullable => 0 },
  "status",
  {
    data_type => "enum",
    extra => {
      list => ["pending", "running", "complete", "broken", "canceled"],
    },
    is_nullable => 0,
  },
  "parameters",
  { data_type => "longtext", is_nullable => 1 },
  "fields",
  { data_type => "longtext", is_nullable => 1 },
  "test_file_id",
  { data_type => "binary", is_foreign_key => 1, is_nullable => 1, size => 16 },
  "name",
  { data_type => "text", is_nullable => 1 },
  "fail",
  { data_type => "tinyint", is_nullable => 1 },
  "retry",
  { data_type => "tinyint", is_nullable => 1 },
  "exit_code",
  { data_type => "integer", is_nullable => 1 },
  "launch",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    is_nullable => 1,
  },
  "start",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    is_nullable => 1,
  },
  "ended",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    is_nullable => 1,
  },
  "duration",
  { data_type => "double precision", is_nullable => 1 },
  "pass_count",
  { data_type => "bigint", is_nullable => 1 },
  "fail_count",
  { data_type => "bigint", is_nullable => 1 },
  "coverage_manager",
  { data_type => "text", is_nullable => 1 },
  "stdout",
  { data_type => "longtext", is_nullable => 1 },
  "stderr",
  { data_type => "longtext", is_nullable => 1 },
);
__PACKAGE__->set_primary_key("job_key");
__PACKAGE__->add_unique_constraint("job_id", ["job_id", "job_try"]);
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


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-03-02 16:05:19
use Test2::Harness::UI::UUID qw/uuid_inflate uuid_deflate/;
__PACKAGE__->inflate_column('test_file_id' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
__PACKAGE__->inflate_column('job_id' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
__PACKAGE__->inflate_column('job_key' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
__PACKAGE__->inflate_column('run_id' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
# DO NOT MODIFY ANY PART OF THIS FILE

1;
