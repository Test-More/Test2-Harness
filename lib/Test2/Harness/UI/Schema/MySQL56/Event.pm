use utf8;
package Test2::Harness::UI::Schema::Result::Event;

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
__PACKAGE__->table("events");
__PACKAGE__->add_columns(
  "event_id",
  { data_type => "char", is_nullable => 0, size => 36 },
  "job_key",
  { data_type => "char", is_foreign_key => 1, is_nullable => 0, size => 36 },
  "event_ord",
  { data_type => "bigint", is_nullable => 0 },
  "insert_ord",
  { data_type => "bigint", is_auto_increment => 1, is_nullable => 0 },
  "has_binary",
  { data_type => "tinyint", default_value => 0, is_nullable => 0 },
  "is_subtest",
  { data_type => "tinyint", default_value => 0, is_nullable => 0 },
  "is_diag",
  { data_type => "tinyint", default_value => 0, is_nullable => 0 },
  "is_harness",
  { data_type => "tinyint", default_value => 0, is_nullable => 0 },
  "is_time",
  { data_type => "tinyint", default_value => 0, is_nullable => 0 },
  "stamp",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    is_nullable => 1,
  },
  "parent_id",
  { data_type => "char", is_nullable => 1, size => 36 },
  "trace_id",
  { data_type => "char", is_nullable => 1, size => 36 },
  "nested",
  { data_type => "integer", default_value => 0, is_nullable => 1 },
  "facets",
  { data_type => "longtext", is_nullable => 1 },
  "facets_line",
  { data_type => "bigint", is_nullable => 1 },
  "orphan",
  { data_type => "longtext", is_nullable => 1 },
  "orphan_line",
  { data_type => "bigint", is_nullable => 1 },
);
__PACKAGE__->set_primary_key("event_id");
__PACKAGE__->add_unique_constraint("insert_ord", ["insert_ord", "job_key"]);
__PACKAGE__->has_many(
  "binaries",
  "Test2::Harness::UI::Schema::Result::Binary",
  { "foreign.event_id" => "self.event_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->belongs_to(
  "job_key",
  "Test2::Harness::UI::Schema::Result::Job",
  { job_key => "job_key" },
  { is_deferrable => 1, on_delete => "RESTRICT", on_update => "RESTRICT" },
);
__PACKAGE__->has_many(
  "reportings",
  "Test2::Harness::UI::Schema::Result::Reporting",
  { "foreign.event_id" => "self.event_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-14 17:04:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:4y7UOImI0BaM9MSR/TJRVQ


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
