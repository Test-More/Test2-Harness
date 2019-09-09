use utf8;
package Test2::Harness::UI::Schema::Result::Duration;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Test2::Harness::UI::Schema::Result::Duration

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 COMPONENTS LOADED

=over 4

=item * L<DBIx::Class::InflateColumn::DateTime>

=item * L<DBIx::Class::InflateColumn::Serializer>

=item * L<DBIx::Class::InflateColumn::Serializer::JSON>

=item * L<DBIx::Class::Tree::AdjacencyList>

=item * L<DBIx::Class::UUIDColumns>

=back

=cut

__PACKAGE__->load_components(
  "InflateColumn::DateTime",
  "InflateColumn::Serializer",
  "InflateColumn::Serializer::JSON",
  "Tree::AdjacencyList",
  "UUIDColumns",
);

=head1 TABLE: C<durations>

=cut

__PACKAGE__->table("durations");

=head1 ACCESSORS

=head2 project_id

  data_type: 'uuid'
  is_foreign_key: 1
  is_nullable: 0
  size: 16

=head2 rel_file

  data_type: 'text'
  is_nullable: 0

=head2 duration

  data_type: 'double precision'
  is_nullable: 0

=head2 added

  data_type: 'timestamp'
  default_value: current_timestamp
  is_nullable: 0
  original: {default_value => \"now()"}

=cut

__PACKAGE__->add_columns(
  "project_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "rel_file",
  { data_type => "text", is_nullable => 0 },
  "duration",
  { data_type => "double precision", is_nullable => 0 },
  "added",
  {
    data_type     => "timestamp",
    default_value => \"current_timestamp",
    is_nullable   => 0,
    original      => { default_value => \"now()" },
  },
);

=head1 RELATIONS

=head2 project

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::Project>

=cut

__PACKAGE__->belongs_to(
  "project",
  "Test2::Harness::UI::Schema::Result::Project",
  { project_id => "project_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2019-09-09 13:14:05
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:rDuHphPOsYns35l8oM9l9g


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
