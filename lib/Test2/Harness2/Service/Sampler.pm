package Test2::Harness2::Service::Sampler;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Time::HiRes qw/time/;

use Test2::Harness2::Util::Socket qw/connect_unix write_frame/;
use Test2::Harness2::Util::Zstd qw/compress_blob/;
use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::SystemLoad;

use Object::HashBase qw{
    <workdir
    <name
    <interval
    <harness_socket
    <source
    +conn
    +next_at
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Service';

use constant DEFAULT_INTERVAL => 0.2;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Service::Sampler - Dedicated process that samples system load.

=head1 DESCRIPTION

A minimal service whose only job is to sample CPU and memory load on a fixed
cadence and report each snapshot to the main harness service. Because the
process does nothing else, its loop interval is steady -- which matters: CPU
percentage is computed from the delta between two readings, so a consistent
interval is what makes the number meaningful.

It consumes L<Test2::Harness2::Role::Service> for consistency with the other
services (so it runs under a collector and is tracked like one), but it never
serves requests of its own: it opens one outbound connection to the harness
socket and, each C<service_tick>, samples via L<Test2::Harness2::SystemLoad> and
writes a C<system_load> request frame. If that write fails the harness is gone,
so the sampler stops.

=head1 ATTRIBUTES

=over 4

=item interval

Seconds between samples. Defaults to 0.2.

=item harness_socket (required)

Path to the main harness service socket to report snapshots to.

=item workdir (required)

Working directory (for the role's own -- unused -- listen socket).

=item name

Service name. Defaults to C<sampler>.

=item source

The L<Test2::Harness2::SystemLoad> instance. Vivified by default.

=back

=cut

sub init ($self) {
    $self->{+NAME}     //= 'sampler';
    $self->{+INTERVAL} //= DEFAULT_INTERVAL;
    $self->{+SOURCE}   //= Test2::Harness2::SystemLoad->new;

    croak "'workdir' is required"
        unless defined $self->{+WORKDIR} && length $self->{+WORKDIR};
    croak "'harness_socket' is required"
        unless defined $self->{+HARNESS_SOCKET} && length $self->{+HARNESS_SOCKET};

    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item $self->service_on_start

Connect to the harness socket and arm the first sample.

=item $self->service_tick

Once per C<interval>, take a snapshot and report it; stop if the harness socket
has gone away.

=back

=cut

sub service_on_start ($self) {
    $self->{+CONN}    = connect_unix($self->{+HARNESS_SOCKET});
    $self->{+NEXT_AT} = time;                                     # sample on the first tick
    return;
}

sub service_tick ($self) {
    my $now = time;
    return if $now < $self->{+NEXT_AT};

    # Advance by whole intervals; resync if we fell more than an interval behind
    # (a stall should not produce a burst of catch-up samples).
    $self->{+NEXT_AT} += $self->{+INTERVAL};
    $self->{+NEXT_AT} = $now + $self->{+INTERVAL} if $self->{+NEXT_AT} < $now;

    my $snap  = $self->{+SOURCE}->sample;
    my $frame = compress_blob(encode_json({request => 'system_load', load => $snap}));

    $self->stop_service
        unless eval { write_frame($self->{+CONN}, $frame); 1 };

    return;
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
