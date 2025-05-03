package App::Yath::Server::Request;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp qw/croak/;

use Test2::Util::UUID qw/gen_uuid/;
use App::Yath::Schema::Util qw/format_uuid_for_db/;

use parent 'Plack::Request';
use Test2::Harness::Util::HashBase qw{
    +session
    +session_host
    <schema
    user
};

sub new {
    my $class = shift;
    my(%params) = @_;

    croak "'env' is a required attribute"    unless $params{env};
    croak "'schema' is a required attribute" unless $params{+SCHEMA};

    return bless(\%params, $class);
}

sub session {
    my $self = shift;

    return $self->{+SESSION} if $self->{+SESSION};

    my $schema = $self->schema;

    my $session;
    my $cookies = $self->cookies;

    if (my $uuid = $cookies->{uuid}) {
        $session = $schema->resultset('Session')->find({session_uuid => $uuid});
        $session = undef unless $session && $session->active;
    }

    my $uuid = gen_uuid();
    $session ||= $schema->resultset('Session')->create(
        {session_uuid => format_uuid_for_db($uuid)},
    );

    return $self->{+SESSION} = $session;
}

sub session_host {
    my $self = shift;

    return $self->{+SESSION_HOST} if $self->{+SESSION_HOST};

    my $session = $self->session or return undef;

    my $schema = $self->schema;

    $schema->txn_begin;

    my $host = $schema->resultset('SessionHost')->find(
        {
            session_id => $session->session_id,
            address    => $self->address // 'SOCKET',
            agent      => $self->user_agent,
        }
    );

    $host //= $schema->resultset('SessionHost')->create({
        session_id      => $session->session_id,
        address         => $self->address // 'SOCKET',
        agent           => $self->user_agent,
    });

    $schema->txn_commit;

    return $self->{+SESSION_HOST} = $host;
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Server::Request - web request

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

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

=pod

=cut POD NEEDS AUDIT

