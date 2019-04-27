use utf8;
package Test2::Harness::UI::Schema::Result::EmailVerificationCode;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Test2::Harness::UI::Schema::Result::EmailVerificationCode

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

=head1 TABLE: C<email_verification_codes>

=cut

__PACKAGE__->table("email_verification_codes");

=head1 ACCESSORS

=head2 evcode_id

  data_type: 'uuid'
  default_value: uuid_generate_v4()
  is_nullable: 0
  size: 16

=head2 email_id

  data_type: 'uuid'
  is_foreign_key: 1
  is_nullable: 0
  size: 16

=cut

__PACKAGE__->add_columns(
  "evcode_id",
  {
    data_type => "uuid",
    default_value => \"uuid_generate_v4()",
    is_nullable => 0,
    size => 16,
  },
  "email_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
);

=head1 PRIMARY KEY

=over 4

=item * L</evcode_id>

=back

=cut

__PACKAGE__->set_primary_key("evcode_id");

=head1 UNIQUE CONSTRAINTS

=head2 C<email_verification_codes_email_id_key>

=over 4

=item * L</email_id>

=back

=cut

__PACKAGE__->add_unique_constraint("email_verification_codes_email_id_key", ["email_id"]);

=head1 RELATIONS

=head2 email

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::Email>

=cut

__PACKAGE__->belongs_to(
  "email",
  "Test2::Harness::UI::Schema::Result::Email",
  { email_id => "email_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2019-04-26 08:35:09
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:GxTeyaqCuLWYSAFvqzjtUQ


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
