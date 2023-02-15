use utf8;
package Test2::Harness::UI::Schema::Result::Session;

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
__PACKAGE__->table("sessions");
__PACKAGE__->add_columns(
  "session_id",
  { data_type => "char", is_nullable => 0, size => 36 },
  "active",
  { data_type => "tinyint", default_value => 1, is_nullable => 1 },
);
__PACKAGE__->set_primary_key("session_id");
__PACKAGE__->has_many(
  "session_hosts",
  "Test2::Harness::UI::Schema::Result::SessionHost",
  { "foreign.session_id" => "self.session_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2023-02-14 17:04:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:WaWIwGikLWsv2tIIGURWAw


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
