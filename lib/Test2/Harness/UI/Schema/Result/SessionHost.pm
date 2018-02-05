use utf8;
package Test2::Harness::UI::Schema::Result::SessionHost;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Test2::Harness::UI::Schema::Result::SessionHost

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

=back

=cut

__PACKAGE__->load_components(
  "InflateColumn::DateTime",
  "InflateColumn::Serializer",
  "InflateColumn::Serializer::JSON",
  "Tree::AdjacencyList",
);

=head1 TABLE: C<session_hosts>

=cut

__PACKAGE__->table("session_hosts");

=head1 ACCESSORS

=head2 session_host_id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'session_hosts_session_host_id_seq'

=head2 session_id

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 user_id

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 1

=head2 created

  data_type: 'timestamp'
  default_value: current_timestamp
  is_nullable: 0
  original: {default_value => \"now()"}

=head2 accessed

  data_type: 'timestamp'
  default_value: current_timestamp
  is_nullable: 0
  original: {default_value => \"now()"}

=head2 address

  data_type: 'text'
  is_nullable: 0

=head2 agent

  data_type: 'text'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "session_host_id",
  {
    data_type         => "integer",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "session_hosts_session_host_id_seq",
  },
  "session_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "user_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 1 },
  "created",
  {
    data_type     => "timestamp",
    default_value => \"current_timestamp",
    is_nullable   => 0,
    original      => { default_value => \"now()" },
  },
  "accessed",
  {
    data_type     => "timestamp",
    default_value => \"current_timestamp",
    is_nullable   => 0,
    original      => { default_value => \"now()" },
  },
  "address",
  { data_type => "text", is_nullable => 0 },
  "agent",
  { data_type => "text", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</session_host_id>

=back

=cut

__PACKAGE__->set_primary_key("session_host_id");

=head1 UNIQUE CONSTRAINTS

=head2 C<session_hosts_session_id_address_agent_key>

=over 4

=item * L</session_id>

=item * L</address>

=item * L</agent>

=back

=cut

__PACKAGE__->add_unique_constraint(
  "session_hosts_session_id_address_agent_key",
  ["session_id", "address", "agent"],
);

=head1 RELATIONS

=head2 session

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::Session>

=cut

__PACKAGE__->belongs_to(
  "session",
  "Test2::Harness::UI::Schema::Result::Session",
  { session_id => "session_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);

=head2 user

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::User>

=cut

__PACKAGE__->belongs_to(
  "user",
  "Test2::Harness::UI::Schema::Result::User",
  { user_id => "user_id" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "NO ACTION",
    on_update     => "NO ACTION",
  },
);


# Created by DBIx::Class::Schema::Loader v0.07048 @ 2018-02-05 12:00:37
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:WiA4RpkrlKASKEY1jEy8pA


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
