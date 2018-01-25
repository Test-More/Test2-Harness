package Test2::Harness::UI::Schema::Result::User;
use strict;
use warnings;

use Data::GUID;
use Carp qw/croak/;

use parent qw/DBIx::Class::Core/;

use constant COST => 8;

use Crypt::Eksblowfish::Bcrypt qw(bcrypt_hash en_base64 de_base64);

__PACKAGE__->table('users');
__PACKAGE__->add_columns(qw/user_ui_id username pw_hash pw_salt/);
__PACKAGE__->set_primary_key('user_ui_id');
__PACKAGE__->has_many(feeds => 'Test2::Harness::UI::Schema::Result::Feed', 'user_ui_id');
__PACKAGE__->has_many(api_keys => 'Test2::Harness::UI::Schema::Result::APIKey', 'user_ui_id');

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

    $self->pw_hash(en_base64($hash));
    $self->pw_salt(en_base64($salt));
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

    return $self->result_source->schema->resultset('APIKey')->create(
        {
            user_ui_id => $self->user_ui_id,
            value      => $val,
            status     => 'active',
            name       => 'blah',
        }
    );
}

1;
