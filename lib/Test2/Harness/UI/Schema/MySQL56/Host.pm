use utf8;
package Test2::Harness::UI::Schema::Result::Host;

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
__PACKAGE__->table("hosts");
__PACKAGE__->add_columns(
  "host_id",
  { data_type => "char", is_nullable => 0, size => 36 },
  "hostname",
  { data_type => "varchar", is_nullable => 0, size => 512 },
  "test_slots",
  { data_type => "integer", is_nullable => 0 },
);
__PACKAGE__->set_primary_key("host_id");
__PACKAGE__->add_unique_constraint("hostname", ["hostname"]);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2022-07-29 08:37:22
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:gvy/qPJlPE1xs+xfLRd28Q


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
