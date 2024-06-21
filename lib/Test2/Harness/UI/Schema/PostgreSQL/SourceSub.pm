use utf8;
package Test2::Harness::UI::Schema::Result::SourceSub;

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
__PACKAGE__->table("source_subs");
__PACKAGE__->add_columns(
  "source_sub_id",
  { data_type => "uuid", is_nullable => 0, size => 16 },
  "subname",
  { data_type => "varchar", is_nullable => 0, size => 512 },
);
__PACKAGE__->set_primary_key("source_sub_id");
__PACKAGE__->add_unique_constraint("source_subs_subname_key", ["subname"]);
__PACKAGE__->has_many(
  "coverages",
  "Test2::Harness::UI::Schema::Result::Coverage",
  { "foreign.source_sub_id" => "self.source_sub_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-03-02 16:05:20
# DO NOT MODIFY ANY PART OF THIS FILE

1;
