use utf8;
package Test2::Harness::UI::Schema::Result::Event;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Test2::Harness::UI::Schema::Result::Event

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

=head1 TABLE: C<events>

=cut

__PACKAGE__->table("events");

=head1 ACCESSORS

=head2 event_id

  data_type: 'uuid'
  is_nullable: 0
  size: 16

=head2 event_ord

  data_type: 'bigint'
  is_nullable: 0

=head2 job_id

  data_type: 'uuid'
  is_foreign_key: 1
  is_nullable: 0
  size: 16

=head2 parent_id

  data_type: 'uuid'
  is_foreign_key: 1
  is_nullable: 1
  size: 16

=head2 nested

  data_type: 'integer'
  is_nullable: 0

=head2 causes_fail

  data_type: 'boolean'
  is_nullable: 0

=head2 no_render

  data_type: 'boolean'
  is_nullable: 0

=head2 no_display

  data_type: 'boolean'
  is_nullable: 0

=head2 is_parent

  data_type: 'boolean'
  is_nullable: 0

=head2 is_assert

  data_type: 'boolean'
  is_nullable: 0

=head2 is_plan

  data_type: 'boolean'
  is_nullable: 0

=head2 is_diag

  data_type: 'boolean'
  is_nullable: 0

=head2 is_orphan

  data_type: 'boolean'
  is_nullable: 0

=head2 assert_pass

  data_type: 'boolean'
  is_nullable: 1

=head2 plan_count

  data_type: 'integer'
  is_nullable: 1

=head2 facets

  data_type: 'jsonb'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "event_id",
  { data_type => "uuid", is_nullable => 0, size => 16 },
  "event_ord",
  { data_type => "bigint", is_nullable => 0 },
  "job_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "parent_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 1, size => 16 },
  "nested",
  { data_type => "integer", is_nullable => 0 },
  "causes_fail",
  { data_type => "boolean", is_nullable => 0 },
  "no_render",
  { data_type => "boolean", is_nullable => 0 },
  "no_display",
  { data_type => "boolean", is_nullable => 0 },
  "is_parent",
  { data_type => "boolean", is_nullable => 0 },
  "is_assert",
  { data_type => "boolean", is_nullable => 0 },
  "is_plan",
  { data_type => "boolean", is_nullable => 0 },
  "is_diag",
  { data_type => "boolean", is_nullable => 0 },
  "is_orphan",
  { data_type => "boolean", is_nullable => 0 },
  "assert_pass",
  { data_type => "boolean", is_nullable => 1 },
  "plan_count",
  { data_type => "integer", is_nullable => 1 },
  "facets",
  { data_type => "jsonb", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</event_id>

=back

=cut

__PACKAGE__->set_primary_key("event_id");

=head1 RELATIONS

=head2 event_comments

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::EventComment>

=cut

__PACKAGE__->has_many(
  "event_comments",
  "Test2::Harness::UI::Schema::Result::EventComment",
  { "foreign.event_id" => "self.event_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 event_lines

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::EventLine>

=cut

__PACKAGE__->has_many(
  "event_lines",
  "Test2::Harness::UI::Schema::Result::EventLine",
  { "foreign.event_id" => "self.event_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 events

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::Event>

=cut

__PACKAGE__->has_many(
  "events",
  "Test2::Harness::UI::Schema::Result::Event",
  { "foreign.parent_id" => "self.event_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 job

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::Job>

=cut

__PACKAGE__->belongs_to(
  "job",
  "Test2::Harness::UI::Schema::Result::Job",
  { job_id => "job_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);

=head2 parent_rel

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::Event>

=cut

__PACKAGE__->belongs_to(
  "parent_rel",
  "Test2::Harness::UI::Schema::Result::Event",
  { event_id => "parent_id" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "NO ACTION",
    on_update     => "NO ACTION",
  },
);


# Created by DBIx::Class::Schema::Loader v0.07048 @ 2018-02-12 08:17:03
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:q75JUNWE7Ea0YUSVlZ6idg

__PACKAGE__->parent_column('parent_id');

sub run  { shift->job->run }
sub user { shift->job->run->user }

sub verify_access {
    my $self = shift;
    my ($type, $user) = @_;

    my $run = $self->run;

    return $run->verify_access($type, $user);
}


1;
