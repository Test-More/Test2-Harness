use utf8;
package Test2::Harness::UI::Schema::Result::User;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Test2::Harness::UI::Schema::Result::User

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

=head1 TABLE: C<users>

=cut

__PACKAGE__->table("users");

=head1 ACCESSORS

=head2 user_id

  data_type: 'uuid'
  default_value: uuid_generate_v4()
  is_nullable: 0
  size: 16

=head2 username

  data_type: 'citext'
  is_nullable: 0

=head2 pw_hash

  data_type: 'varchar'
  is_nullable: 0
  size: 31

=head2 pw_salt

  data_type: 'varchar'
  is_nullable: 0
  size: 22

=head2 realname

  data_type: 'text'
  is_nullable: 0

=head2 role

  data_type: 'enum'
  default_value: 'user'
  extra: {custom_type_name => "user_type",list => ["admin","user"]}
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "user_id",
  {
    data_type => "uuid",
    default_value => \"uuid_generate_v4()",
    is_nullable => 0,
    size => 16,
  },
  "username",
  { data_type => "citext", is_nullable => 0 },
  "pw_hash",
  { data_type => "varchar", is_nullable => 0, size => 31 },
  "pw_salt",
  { data_type => "varchar", is_nullable => 0, size => 22 },
  "realname",
  { data_type => "text", is_nullable => 0 },
  "role",
  {
    data_type => "enum",
    default_value => "user",
    extra => { custom_type_name => "user_type", list => ["admin", "user"] },
    is_nullable => 0,
  },
);

=head1 PRIMARY KEY

=over 4

=item * L</user_id>

=back

=cut

__PACKAGE__->set_primary_key("user_id");

=head1 UNIQUE CONSTRAINTS

=head2 C<users_username_key>

=over 4

=item * L</username>

=back

=cut

__PACKAGE__->add_unique_constraint("users_username_key", ["username"]);

=head1 RELATIONS

=head2 api_keys

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::ApiKey>

=cut

__PACKAGE__->has_many(
  "api_keys",
  "Test2::Harness::UI::Schema::Result::ApiKey",
  { "foreign.user_id" => "self.user_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 emails

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::Email>

=cut

__PACKAGE__->has_many(
  "emails",
  "Test2::Harness::UI::Schema::Result::Email",
  { "foreign.user_id" => "self.user_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 permissions

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::Permission>

=cut

__PACKAGE__->has_many(
  "permissions",
  "Test2::Harness::UI::Schema::Result::Permission",
  { "foreign.user_id" => "self.user_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 primary_email

Type: might_have

Related object: L<Test2::Harness::UI::Schema::Result::PrimaryEmail>

=cut

__PACKAGE__->might_have(
  "primary_email",
  "Test2::Harness::UI::Schema::Result::PrimaryEmail",
  { "foreign.user_id" => "self.user_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 runs

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::Run>

=cut

__PACKAGE__->has_many(
  "runs",
  "Test2::Harness::UI::Schema::Result::Run",
  { "foreign.user_id" => "self.user_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 session_hosts

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::SessionHost>

=cut

__PACKAGE__->has_many(
  "session_hosts",
  "Test2::Harness::UI::Schema::Result::SessionHost",
  { "foreign.user_id" => "self.user_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2019-04-27 02:58:27
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:Qzlgwn31ezLK5DZmX1rzcw

our $VERSION = '0.000028';

use Data::GUID;
use Carp qw/croak/;

use constant COST => 8;

use Crypt::Eksblowfish::Bcrypt qw(bcrypt_hash en_base64 de_base64);

sub new {
    my $class = shift;
    my ($attrs) = @_;

    if (my $pw = delete $attrs->{password}) {
        my $salt = $class->gen_salt;
        my $hash = bcrypt_hash({key_nul => 1, cost => COST, salt => $salt}, $pw);

        $attrs->{pw_hash} = en_base64($hash);
        $attrs->{pw_salt} = en_base64($salt);
    }

    my $new = $class->next::method($attrs);

    return $new;
}

sub verify_password {
    my $self = shift;
    my ($pw) = @_;

    my $hash = en_base64(bcrypt_hash({key_nul => 1, cost => COST, salt => de_base64($self->pw_salt)}, $pw));
    return $hash eq $self->pw_hash;
}

sub set_password {
    my $self = shift;
    my ($pw) = @_;

    my $salt = $self->gen_salt;
    my $hash = bcrypt_hash({key_nul => 1, cost => COST, salt => $salt}, $pw);

    $self->update({pw_hash => en_base64($hash), pw_salt => en_base64($salt)});
}

sub gen_salt {
    my $salt = '';
    $salt .= chr(rand() * 256) while length($salt) < 16;
    return $salt;
}

sub gen_api_key {
    my $self = shift;
    my ($name) = @_;

    croak "Must provide a key name"
        unless defined($name);

    my $guid = Data::GUID->new;
    my $val  = $guid->as_string;

    return $self->result_source->schema->resultset('ApiKey')->create(
        {
            user_id => $self->user_id,
            value   => $val,
            status  => 'active',
            name    => $name,
        }
    );
}

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
