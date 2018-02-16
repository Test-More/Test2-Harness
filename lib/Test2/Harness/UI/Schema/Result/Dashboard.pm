use utf8;
package Test2::Harness::UI::Schema::Result::Dashboard;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Test2::Harness::UI::Schema::Result::Dashboard

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

=head1 TABLE: C<dashboards>

=cut

__PACKAGE__->table("dashboards");

=head1 ACCESSORS

=head2 dashboard_id

  data_type: 'uuid'
  default_value: uuid_generate_v4()
  is_nullable: 0
  size: 16

=head2 user_id

  data_type: 'uuid'
  is_foreign_key: 1
  is_nullable: 0
  size: 16

=head2 is_public

  data_type: 'boolean'
  is_nullable: 1

=head2 name

  data_type: 'text'
  is_nullable: 0

=head2 weight

  data_type: 'smallint'
  default_value: 0
  is_nullable: 0

=head2 show_passes

  data_type: 'boolean'
  is_nullable: 0

=head2 show_failures

  data_type: 'boolean'
  is_nullable: 0

=head2 show_pending

  data_type: 'boolean'
  is_nullable: 0

=head2 show_shared

  data_type: 'boolean'
  is_nullable: 0

=head2 show_mine

  data_type: 'boolean'
  is_nullable: 0

=head2 show_protected

  data_type: 'boolean'
  is_nullable: 0

=head2 show_public

  data_type: 'boolean'
  is_nullable: 0

=head2 show_signoff_only

  data_type: 'boolean'
  is_nullable: 0

=head2 show_errors_only

  data_type: 'boolean'
  is_nullable: 0

=head2 show_columns

  data_type: 'jsonb'
  is_nullable: 0

=head2 show_project

  data_type: 'citext'
  is_nullable: 1

=head2 show_version

  data_type: 'citext'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "dashboard_id",
  {
    data_type => "uuid",
    default_value => \"uuid_generate_v4()",
    is_nullable => 0,
    size => 16,
  },
  "user_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "is_public",
  { data_type => "boolean", is_nullable => 1 },
  "name",
  { data_type => "text", is_nullable => 0 },
  "weight",
  { data_type => "smallint", default_value => 0, is_nullable => 0 },
  "show_passes",
  { data_type => "boolean", is_nullable => 0 },
  "show_failures",
  { data_type => "boolean", is_nullable => 0 },
  "show_pending",
  { data_type => "boolean", is_nullable => 0 },
  "show_shared",
  { data_type => "boolean", is_nullable => 0 },
  "show_mine",
  { data_type => "boolean", is_nullable => 0 },
  "show_protected",
  { data_type => "boolean", is_nullable => 0 },
  "show_public",
  { data_type => "boolean", is_nullable => 0 },
  "show_signoff_only",
  { data_type => "boolean", is_nullable => 0 },
  "show_errors_only",
  { data_type => "boolean", is_nullable => 0 },
  "show_columns",
  { data_type => "jsonb", is_nullable => 0 },
  "show_project",
  { data_type => "citext", is_nullable => 1 },
  "show_version",
  { data_type => "citext", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</dashboard_id>

=back

=cut

__PACKAGE__->set_primary_key("dashboard_id");

=head1 RELATIONS

=head2 user

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::User>

=cut

__PACKAGE__->belongs_to(
  "user",
  "Test2::Harness::UI::Schema::Result::User",
  { user_id => "user_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07048 @ 2018-02-12 14:32:56
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:2chZG5K/UlwbbdIiUDc74Q

__PACKAGE__->inflate_column(
    show_columns => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('show_columns', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('show_columns', {}),
    },
);

# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
