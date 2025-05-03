package App::Yath::Client;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp qw/croak/;
use File::Spec;

use App::Yath::IPC;

use Test2::Harness::IPC::Protocol;

use parent 'Test2::Harness::Client';
use Test2::Harness::Util::HashBase qw{
    <settings
    <ipc <connect
    <yath_ipc
    <ipc_type
    <types
};

sub init {
    my $self = shift;

    my $settings = $self->{+SETTINGS} or croak "'settings' is a required attribute";
    croak "'ipc' is not set, and there is no 'ipc' category in the settings"
        unless $self->{+IPC} or $settings->ipc;

    my $types = $self->{+TYPES} //= ['daemon'];

    my $yipc = $self->{+YATH_IPC} //= App::Yath::IPC->new(settings => $settings);
    my ($ipc, $con) = $yipc->connect(@$types);

    $self->{+IPC} = $ipc;
    $self->{+CONNECT} = $con;

    $self->SUPER::init();
}

sub ipc_text {
    my $self = shift;

    my $ipc_s = $self->yath_ipc->connected;

    my $out = "Harness instance pid " . $ipc_s->{peer_pid};
    if (my $prot = $ipc_s->{protocol}) {
        $prot =~ s/^Test2::Harness::IPC::Protocol:://;
        $out .= " $prot";

        if (my $addr = $ipc_s->{address}) {
            $addr = File::Spec->abs2rel($addr) if -e $addr;
            $out .= " $addr";

            if (my $port = $ipc_s->{port}) {
                $out .= ":$port";
            }
        }
    }

    return $out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Client - FIXME

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

