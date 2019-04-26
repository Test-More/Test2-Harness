use utf8;
package Test2::Harness::UI::Schema::Result::Email;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Test2::Harness::UI::Schema::Result::Email

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

=head1 TABLE: C<email>

=cut

__PACKAGE__->table("email");

=head1 ACCESSORS

=head2 email_id

  data_type: 'uuid'
  default_value: uuid_generate_v4()
  is_nullable: 0
  size: 16

=head2 user_id

  data_type: 'uuid'
  is_foreign_key: 1
  is_nullable: 0
  size: 16

=head2 local

  data_type: 'citext'
  is_nullable: 0

=head2 domain

  data_type: 'citext'
  is_nullable: 0

=head2 verified

  data_type: 'boolean'
  default_value: false
  is_nullable: 0

=head2 is_primary

  data_type: 'boolean'
  default_value: false
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "email_id",
  {
    data_type => "uuid",
    default_value => \"uuid_generate_v4()",
    is_nullable => 0,
    size => 16,
  },
  "user_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "local",
  { data_type => "citext", is_nullable => 0 },
  "domain",
  { data_type => "citext", is_nullable => 0 },
  "verified",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
  "is_primary",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</email_id>

=back

=cut

__PACKAGE__->set_primary_key("email_id");

=head1 UNIQUE CONSTRAINTS

=head2 C<email_local_domain_key>

=over 4

=item * L</local>

=item * L</domain>

=back

=cut

__PACKAGE__->add_unique_constraint("email_local_domain_key", ["local", "domain"]);

=head2 C<email_user_id_is_primary_key>

=over 4

=item * L</user_id>

=item * L</is_primary>

=back

=cut

__PACKAGE__->add_unique_constraint("email_user_id_is_primary_key", ["user_id", "is_primary"]);

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


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2019-04-26 01:45:09
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:+lqBd4HxhHMsayYkX4zAOA


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
