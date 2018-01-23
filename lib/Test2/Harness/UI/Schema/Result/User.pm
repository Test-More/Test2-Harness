package Test2::Harness::UI::Schema::Result::User;
use strict;
use warnings;

use constant COST => 8;

use Crypt::Eksblowfish::Bcrypt qw(bcrypt_hash en_base64 dec_base64);

__PACKAGE__->table('users');
__PACKAGE__->add_columns(qw/user_id username pw_hash pw_salt/);
__PACKAGE__->add_primary_key('user_id');
__PACKAGE__->has_many(runs => 'Test2::Harness::UI::Schema::Result::Run');

sub new {
    my $class = shift;
    my ($attrs) = @_;

    if (my $pw = delete $attr->{password}) {
        my $salt = $self->gen_salt;
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

    my $hash = en_base64(bcrypt_hash({key_nul => 1, cost => COST, salt => dev_base64($self->pw_salt)}, $pw));
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
    my $salt;
    $salt .= chr(rand() * 256) while length($salt) < 16;
    return $salt;
}

1;
