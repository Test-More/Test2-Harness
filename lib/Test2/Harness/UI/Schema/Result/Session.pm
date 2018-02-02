use utf8;
package Test2::Harness::UI::Schema::Result::Session;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Test2::Harness::UI::Schema::Result::Session

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 COMPONENTS LOADED

=over 4

=item * L<DBIx::Class::InflateColumn::DateTime>

=item * L<DBIx::Class::InflateColumn::Serializer>

=item * L<DBIx::Class::InflateColumn::Serializer::JSON>

=back

=cut

__PACKAGE__->load_components(
  "InflateColumn::DateTime",
  "InflateColumn::Serializer",
  "InflateColumn::Serializer::JSON",
);

=head1 TABLE: C<sessions>

=cut

__PACKAGE__->table("sessions");

=head1 ACCESSORS

=head2 session_ui_id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'sessions_session_ui_id_seq'

=head2 session_id

  data_type: 'varchar'
  is_nullable: 0
  size: 36

=head2 active

  data_type: 'boolean'
  default_value: true
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "session_ui_id",
  {
    data_type         => "integer",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "sessions_session_ui_id_seq",
  },
  "session_id",
  { data_type => "varchar", is_nullable => 0, size => 36 },
  "active",
  { data_type => "boolean", default_value => \"true", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</session_ui_id>

=back

=cut

__PACKAGE__->set_primary_key("session_ui_id");

=head1 UNIQUE CONSTRAINTS

=head2 C<sessions_session_id_key>

=over 4

=item * L</session_id>

=back

=cut

__PACKAGE__->add_unique_constraint("sessions_session_id_key", ["session_id"]);

=head1 RELATIONS

=head2 session_hosts

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::SessionHost>

=cut

__PACKAGE__->has_many(
  "session_hosts",
  "Test2::Harness::UI::Schema::Result::SessionHost",
  { "foreign.session_ui_id" => "self.session_ui_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07048 @ 2018-02-02 15:01:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:uDPS3JTA09EnGa7IDy9zTg


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
