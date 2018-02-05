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

=back

=cut

__PACKAGE__->load_components(
  "InflateColumn::DateTime",
  "InflateColumn::Serializer",
  "InflateColumn::Serializer::JSON",
  "Tree::AdjacencyList",
);

=head1 TABLE: C<api_keys>

=cut

__PACKAGE__->table("api_keys");

=head1 ACCESSORS

=head2 api_key_id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'api_keys_api_key_id_seq'

=head2 user_id

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

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
    data_type         => "integer",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "api_keys_api_key_id_seq",
  },
  "user_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
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


# Created by DBIx::Class::Schema::Loader v0.07048 @ 2018-02-05 12:00:37
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:o3RhAw7irW7TRtqhm/2qEQ


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
