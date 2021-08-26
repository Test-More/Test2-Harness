package Test2::Harness::UI::Schema::Result::User;
use utf8;
use strict;
use warnings;

use Carp qw/confess/;
confess "You must first load a Test2::Harness::UI::Schema::NAME module"
    unless $Test2::Harness::UI::Schema::LOADED;

our $VERSION = '0.000083';

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

=head1 NAME

Test2::Harness::UI::Schema::Result::User

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
