use utf8;
package Test2::Harness::UI::Schema::Result::DurationsState;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Test2::Harness::UI::Schema::Result::DurationsState

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

=head1 TABLE: C<durations_state>

=cut

__PACKAGE__->table("durations_state");

=head1 ACCESSORS

=head2 state_id

  data_type: 'text'
  is_nullable: 0

=head2 project_id

  data_type: 'uuid'
  is_foreign_key: 1
  is_nullable: 0
  size: 16

=head2 durations

  data_type: 'jsonb'
  is_nullable: 0

=head2 added

  data_type: 'timestamp'
  default_value: current_timestamp
  is_nullable: 0
  original: {default_value => \"now()"}

=cut

__PACKAGE__->add_columns(
  "state_id",
  { data_type => "text", is_nullable => 0 },
  "project_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "durations",
  { data_type => "jsonb", is_nullable => 0 },
  "added",
  {
    data_type     => "timestamp",
    default_value => \"current_timestamp",
    is_nullable   => 0,
    original      => { default_value => \"now()" },
  },
);

=head1 UNIQUE CONSTRAINTS

=head2 C<durations_state_project_id_state_id_key>

=over 4

=item * L</project_id>

=item * L</state_id>

=back

=cut

__PACKAGE__->add_unique_constraint(
  "durations_state_project_id_state_id_key",
  ["project_id", "state_id"],
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


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2019-09-10 11:27:39
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:aLqFnOUY9UHfPhGbdx6zkg

__PACKAGE__->inflate_column(
    durations => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('durations', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('durations', {}),
    },
);

# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
