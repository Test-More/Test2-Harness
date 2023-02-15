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
  { data_type => "uuid", is_nullable => 0, size => 16 },
  "job_key",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "event_ord",
  { data_type => "bigint", is_nullable => 0 },
  "insert_ord",
  {
    data_type         => "bigint",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "events_insert_ord_seq",
  },
  "is_subtest",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
  "is_diag",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
  "is_harness",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
  "is_time",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
  "has_binary",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
  "stamp",
  { data_type => "timestamp", is_nullable => 1 },
  "parent_id",
  { data_type => "uuid", is_nullable => 1, size => 16 },
  "trace_id",
  { data_type => "uuid", is_nullable => 1, size => 16 },
  "nested",
  { data_type => "integer", default_value => 0, is_nullable => 1 },
  "facets",
  { data_type => "jsonb", is_nullable => 1 },
  "facets_line",
  { data_type => "bigint", is_nullable => 1 },
  "orphan",
  { data_type => "jsonb", is_nullable => 1 },
  "orphan_line",
  { data_type => "bigint", is_nullable => 1 },
);
__PACKAGE__->set_primary_key("event_id");
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
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);
__PACKAGE__->has_many(
  "reportings",
  "Test2::Harness::UI::Schema::Result::Reporting",
  { "foreign.event_id" => "self.event_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-14 17:04:45
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:65Qop1Wmt+elazKi2wQ+Hw


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
