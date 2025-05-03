package Test2::Harness::IPC::Connection;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp qw/confess croak longmess/;

use Test2::Harness::IPC::Util qw/ipc_warn/;

use Test2::Harness::Util::HashBase qw/<protocol/;

sub init {
    my $self = shift;
    croak "'protocol' is a required field" unless $self->{+PROTOCOL};
}

sub handles_for_select { }

sub callback { confess "\nProtocol $_[0] does not implement callback()" }

sub active       { confess "\nProtocol $_[0] does not implement active()" }
sub health_check { confess "\nProtocol $_[0] does not implement health_check()" }
sub expired      { confess "\nProtocol $_[0] does not implement expired()" }

sub send_message { confess "\nProtocol $_[0] does not implement send_message()" }
sub send_request { confess "\nProtocol $_[0] does not implement send_request()" }
sub get_response { confess "\nProtocol $_[0] does not implement get_response()" }

sub send_and_get {
    my $self = shift;
    my ($api_call, $args, %params) = @_;

    my $req = $self->send_request($api_call, $args, %params, return_request => 1);

    return undef if $req->do_not_respond;

    my $id = $req->request_id;
    my $res = $self->get_response($id, blocking => 1);

    unless (($res && $res->api->{success}) || $params{no_die}) {
        ipc_warn($res ? $res->{api} : {error => longmess("No Response")});
        die "IPC error";
    }

    my @caller = caller;
    return $res;
}

sub terminate { }

sub DESTROY { $_[0]->terminate() }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::IPC::Connection - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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

See L<http://dev.perl.org/licenses/>

=cut


=pod

=cut POD NEEDS AUDIT

