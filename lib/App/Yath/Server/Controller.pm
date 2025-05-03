package App::Yath::Server::Controller;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp qw/croak/;

use App::Yath::Server::Response qw/error/;

use Test2::Harness::Util::HashBase qw{
    <request
    <route
    +schema
    <schema_config
    <session
    <session_host
    <single_run
    <single_user
    <user
};

sub init {
    my $self = shift;

    croak "'request' is a required attribute"       unless $self->{+REQUEST};
    croak "'schema_config' is a required attribute" unless $self->{+SCHEMA_CONFIG};

    croak "'single_user' must be defined" unless defined $self->{+SINGLE_USER};
    croak "'single_run' must be defined"  unless defined $self->{+SINGLE_RUN};
}

sub schema { $_[0]->{+SCHEMA} //= $_[0]->{+SCHEMA_CONFIG}->schema }

sub title { 'Yath-Server' }

sub handle { error(501 => "Controller '" . ref($_[0]) . "' did not implement handle()") }

sub requires_user { 0 }

sub auth_check {
    my $self = shift;

    return unless $self->requires_user;

    return error(501 => "Controller '" . ref($_[0]) . "' did not implement verify_user_credentials()")
        unless $self->can('verify_user_credentials');

    return error(401) unless $self->verify_user_credentials();

    return;
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Server::Controller - Base class for yath server controllers.

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

