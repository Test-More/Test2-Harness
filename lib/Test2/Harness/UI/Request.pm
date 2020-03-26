package Test2::Harness::UI::Request;
use strict;
use warnings;

our $VERSION = '0.000028';

use Data::GUID;
use Carp qw/croak/;

use parent 'Plack::Request';

sub new {
    my $class = shift;
    my %params = @_;

    my $env = delete $params{env} or croak "'env' is a required attribute";

    my $self = $class->SUPER::new($env);
    $self->{'config'} = delete $params{config} or croak "'config' is a required attribute";

    return $self;
}

sub schema { $_[0]->{config}->schema }

sub session {
    my $self = shift;

    return $self->{session} if $self->{session};

    my $schema = $self->schema;

    my $session;
    my $cookies = $self->cookies;

    if (my $id = $cookies->{id}) {
        $session = $schema->resultset('Session')->find({session_id => $id});
        $session = undef unless $session && $session->active;
    }

    $session ||= $self->schema->resultset('Session')->create(
        {session_id => Data::GUID->new->as_string},
    );

    $self->{session} = $session;

    # Vivify this
    $self->session_host;

    return $session;
}

sub session_host {
    my $self = shift;

    return $self->{session_host} if $self->{session_host};

    my $session = $self->session or return undef;

    my $schema = $self->schema;

    $schema->txn_begin;

    my $host = $schema->resultset('SessionHost')->find_or_create(
        {
            session_id => $session->session_id,
            address    => $self->address,
            agent      => $self->user_agent,
        }
    );

    $schema->txn_commit;

    return $self->{session_host} = $host;
}

sub user {
    my $self = shift;

    return $self->schema->resultset('User')->find({username => 'root'})
        if $self->{config}->single_user;

    my $host = $self->session_host or return undef;

    return undef unless $host->user_id;
    return $host->user;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Request - web request

=head1 DESCRIPTION

=head1 SYNOPSIS

TODO

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
