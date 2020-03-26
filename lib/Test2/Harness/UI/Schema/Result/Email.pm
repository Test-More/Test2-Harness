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

=head1 RELATIONS

=head2 email_verification_code

Type: might_have

Related object: L<Test2::Harness::UI::Schema::Result::EmailVerificationCode>

=cut

__PACKAGE__->might_have(
  "email_verification_code",
  "Test2::Harness::UI::Schema::Result::EmailVerificationCode",
  { "foreign.email_id" => "self.email_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 primary_email

Type: might_have

Related object: L<Test2::Harness::UI::Schema::Result::PrimaryEmail>

=cut

__PACKAGE__->might_have(
  "primary_email",
  "Test2::Harness::UI::Schema::Result::PrimaryEmail",
  { "foreign.email_id" => "self.email_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

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


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2019-04-27 02:58:27
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:5jzsCZMh/EHh31Pqi4z/hg

our $VERSION = '0.000028';

sub is_primary {
    my $self = shift;
    my $pri = $self->primary_email;
    return $pri ? 1 : 0;
}

sub delete {
    my $self = shift;

    if (my $pri = $self->primary_email) {
        $pri->delete;
    }

    if (my $code = $self->email_verification_code) {
        $code->delete;
    }

    $self->SUPER::delete();
}

sub address {
    my $self = shift;

    return join '@' => ($self->local, $self->domain);
}

# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;

__END__

=pod

=head1 METHODS

=head1 SOURCE

The source code repository for Test2-Harness-UI can be found at
F<http://github.com/Test-More/Test2-Harness-UI/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
