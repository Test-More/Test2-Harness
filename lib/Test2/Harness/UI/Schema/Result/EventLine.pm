use utf8;
package Test2::Harness::UI::Schema::Result::EventLine;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Test2::Harness::UI::Schema::Result::EventLine

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

=head1 TABLE: C<event_lines>

=cut

__PACKAGE__->table("event_lines");

=head1 ACCESSORS

=head2 event_line_id

  data_type: 'bigint'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'event_lines_event_line_id_seq'

=head2 event_id

  data_type: 'uuid'
  is_foreign_key: 1
  is_nullable: 0
  size: 16

=head2 tag

  data_type: 'varchar'
  is_nullable: 0
  size: 8

=head2 facet

  data_type: 'varchar'
  is_nullable: 0
  size: 32

=head2 content

  data_type: 'text'
  is_nullable: 1

=head2 content_json

  data_type: 'jsonb'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "event_line_id",
  {
    data_type         => "bigint",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "event_lines_event_line_id_seq",
  },
  "event_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "tag",
  { data_type => "varchar", is_nullable => 0, size => 8 },
  "facet",
  { data_type => "varchar", is_nullable => 0, size => 32 },
  "content",
  { data_type => "text", is_nullable => 1 },
  "content_json",
  { data_type => "jsonb", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</event_line_id>

=back

=cut

__PACKAGE__->set_primary_key("event_line_id");

=head1 RELATIONS

=head2 event

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::Event>

=cut

__PACKAGE__->belongs_to(
  "event",
  "Test2::Harness::UI::Schema::Result::Event",
  { event_id => "event_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07048 @ 2018-02-08 14:46:44
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:Qmr+4Yfjxur0igKhAhpVSg


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
