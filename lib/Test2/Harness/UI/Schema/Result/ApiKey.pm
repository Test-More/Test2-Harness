use utf8;
package Test2::Harness::UI::Schema::Result::ApiKey;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Test2::Harness::UI::Schema::Result::ApiKey

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

=head1 TABLE: C<api_keys>

=cut

__PACKAGE__->table("api_keys");

=head1 ACCESSORS

=head2 api_key_id

  data_type: 'uuid'
  default_value: uuid_generate_v4()
  is_nullable: 0
  size: 16

=head2 user_id

  data_type: 'uuid'
  is_foreign_key: 1
  is_nullable: 0
  size: 16

=head2 name

  data_type: 'varchar'
  is_nullable: 0
  size: 128

=head2 value

  data_type: 'varchar'
  is_nullable: 0
  size: 36

=head2 status

  data_type: 'enum'
  default_value: 'active'
  extra: {custom_type_name => "api_key_status",list => ["active","disabled","revoked"]}
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "api_key_id",
  {
    data_type => "uuid",
    default_value => \"uuid_generate_v4()",
    is_nullable => 0,
    size => 16,
  },
  "user_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "name",
  { data_type => "varchar", is_nullable => 0, size => 128 },
  "value",
  { data_type => "varchar", is_nullable => 0, size => 36 },
  "status",
  {
    data_type => "enum",
    default_value => "active",
    extra => {
      custom_type_name => "api_key_status",
      list => ["active", "disabled", "revoked"],
    },
    is_nullable => 0,
  },
);

=head1 PRIMARY KEY

=over 4

=item * L</api_key_id>

=back

=cut

__PACKAGE__->set_primary_key("api_key_id");

=head1 UNIQUE CONSTRAINTS

=head2 C<api_keys_value_key>

=over 4

=item * L</value>

=back

=cut

__PACKAGE__->add_unique_constraint("api_keys_value_key", ["value"]);

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


# Created by DBIx::Class::Schema::Loader v0.07048 @ 2018-02-11 19:33:16
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:78M4FVGNk2tRu5Xar5ltIA

sub verify_access {
    my $self = shift;
    my ($type, $user) = @_;

    return 0 unless $user;
    return $self->user_id eq $user->user_id ? 1 : 0;
}

# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
