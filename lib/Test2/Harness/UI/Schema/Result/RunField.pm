use utf8;
package Test2::Harness::UI::Schema::Result::RunField;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Test2::Harness::UI::Schema::Result::RunField

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

=head1 TABLE: C<run_fields>

=cut

__PACKAGE__->table("run_fields");

=head1 ACCESSORS

=head2 run_field_id

  data_type: 'uuid'
  default_value: uuid_generate_v4()
  is_nullable: 0
  size: 16

=head2 run_id

  data_type: 'uuid'
  is_foreign_key: 1
  is_nullable: 0
  size: 16

=head2 name

  data_type: 'citext'
  is_nullable: 0

=head2 details

  data_type: 'citext'
  is_nullable: 0

=head2 link

  data_type: 'citext'
  is_nullable: 1

=head2 data

  data_type: 'jsonb'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "run_field_id",
  {
    data_type => "uuid",
    default_value => \"uuid_generate_v4()",
    is_nullable => 0,
    size => 16,
  },
  "run_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "name",
  { data_type => "citext", is_nullable => 0 },
  "details",
  { data_type => "citext", is_nullable => 0 },
  "link",
  { data_type => "citext", is_nullable => 1 },
  "data",
  { data_type => "jsonb", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</run_field_id>

=back

=cut

__PACKAGE__->set_primary_key("run_field_id");

=head1 RELATIONS

=head2 run

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::Run>

=cut

__PACKAGE__->belongs_to(
  "run",
  "Test2::Harness::UI::Schema::Result::Run",
  { run_id => "run_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2019-08-19 11:52:16
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:i7s9op2Y1VJT42WL/sk6aw

our $VERSION = '0.000011';

sub TO_JSON {
    my $self = shift;
    my %cols = $self->get_columns;
    return \%cols;
}

# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
