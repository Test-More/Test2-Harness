package Test2::Harness2::Service::Sampler;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use POSIX qw/ceil/;
use IO::Select ();
use Time::HiRes qw/time/;

use Test2::Harness2::Util::Socket qw/connect_unix write_frame/;
use Test2::Harness2::Util::Zstd qw/compress_blob/;
use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::SystemLoad;

use Object::HashBase qw{
    <workdir
    <name
    <interval
    <decrease_delay
    <harness_socket
    <source
    +conn
    +sel
    +next_at
    +metrics
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Service';

use constant DEFAULT_INTERVAL       => 0.2;
use constant DEFAULT_DECREASE_DELAY => 1.0;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Service::Sampler - Dedicated process that samples system load.

=head1 DESCRIPTION

A minimal service whose only job is to sample CPU and memory load on a fixed
cadence and report changes to the main harness service. Because the process does
nothing else, its loop interval is steady -- which matters: CPU percentage is
computed from the delta between two readings, so a consistent interval is what
makes the number meaningful.

It samples every tick, but does not report every sample. Both CPU and memory
usage are rounded B<up> to the nearest 5%, and a C<system_load> message is sent
only when one of those rounded values B<changes> enough to warrant it. The same
policy applies to each metric independently:

=over 4

=item *

An B<increase> is reported immediately (load going up matters now).

=item *

A B<decrease> is only reported once the rounded value has stayed below the
last-sent value for at least L</decrease_delay> seconds -- a brief dip is not
trusted as a real drop.

=item *

No change (or a same-valued plateau) sends nothing.

=back

A message is sent when B<either> CPU or memory triggers, and it carries the
current rounded value of both (plus the load average, which rides along). The
reported C<cpu_pct> / C<mem_pct> are the rounded values.

It consumes L<Test2::Harness2::Role::Service> for consistency with the other
services (so it runs under a collector and is tracked like one), but it never
serves requests of its own: it opens one outbound connection to the harness
socket. The sampler stops if that connection breaks (a failed write, or the
harness closing it).

=head1 ATTRIBUTES

=over 4

=item interval

Seconds between samples. Defaults to 0.2.

=item decrease_delay

Seconds a lower rounded metric value (cpu or memory) must persist before a
decrease is reported. Defaults to 1.0 (five ticks at the default interval).

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
    $self->{+NAME}           //= 'sampler';
    $self->{+INTERVAL}       //= DEFAULT_INTERVAL;
    $self->{+DECREASE_DELAY} //= DEFAULT_DECREASE_DELAY;
    $self->{+SOURCE}         //= Test2::Harness2::SystemLoad->new;
    $self->{+METRICS}        //= {};

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

Once per C<interval>, take a snapshot, and report it only when the rounded CPU
or memory usage changed enough to warrant it. Stops if the harness connection
has gone away.

=back

=cut

sub service_on_start ($self) {
    $self->{+CONN}    = connect_unix($self->{+HARNESS_SOCKET});
    $self->{+SEL}     = IO::Select->new($self->{+CONN});
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

    # Notice a vanished harness even on ticks we do not send (steady load means
    # no writes, so a failed write alone could miss it).
    $self->_check_connection;
    return if $self->{service_stopped};

    # Always sample (keeps the CPU delta accurate); only report on a change.
    my $snap = $self->{+SOURCE}->sample;

    my $cpu = defined $snap->{cpu_pct} ? $self->_round_up_5($snap->{cpu_pct}) : undef;
    my $mem = defined $snap->{mem_pct} ? $self->_round_up_5($snap->{mem_pct}) : undef;

    # Track BOTH metrics every tick (do not short-circuit -- each needs its
    # decrease window updated), then send if either says so.
    my $cpu_trig = defined $cpu ? $self->_metric_triggers('cpu', $cpu, $now) : 0;
    my $mem_trig = defined $mem ? $self->_metric_triggers('mem', $mem, $now) : 0;
    return unless $cpu_trig || $mem_trig;

    # A message reports the current rounded value of every metric, so commit them
    # all (whichever triggered, both are now "last sent").
    $self->_commit_metric('cpu', $cpu) if defined $cpu;
    $self->_commit_metric('mem', $mem) if defined $mem;

    $snap->{cpu_pct} = $cpu if defined $cpu;
    $snap->{mem_pct} = $mem if defined $mem;

    my $frame = compress_blob(encode_json({request => 'system_load', load => $snap}));

    $self->stop_service
        unless eval { write_frame($self->{+CONN}, $frame); 1 };

    return;
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $bool = $self->_metric_triggers($name, $rounded, $now)

Apply the reporting policy to one metric's rounded value and return whether it
warrants sending a message. Tracks the metric's decrease window as a side effect
(so it must be called every tick), but does B<not> update the last-sent value --
that happens in C<_commit_metric> once a send is decided. The initial reading
and any increase trigger immediately; a decrease triggers only once the lower
value has held for L</decrease_delay> seconds; an unchanged value triggers
nothing and clears any pending decrease window.

=item $self->_commit_metric($name, $rounded)

Record C<$rounded> as the metric's last-sent value and clear its decrease window.

=item $n = $self->_round_up_5($pct)

Round a percentage B<up> to the nearest multiple of 5, capped at 100.

=item $self->_check_connection

Stop the sampler if the harness has closed its end of the connection.

=back

=cut

sub _metric_triggers ($self, $name, $rounded, $now) {
    my $m    = $self->{+METRICS}{$name} //= {};
    my $last = $m->{last_sent};

    return 1 if !defined $last;      # initial reading
    return 1 if $rounded > $last;    # increase: report now

    if ($rounded == $last) {         # unchanged: clear any decrease window
        delete $m->{decrease_since};
        return 0;
    }

    # Decrease: only trusted once it has persisted for decrease_delay.
    $m->{decrease_since} //= $now;
    return (($now - $m->{decrease_since}) >= $self->{+DECREASE_DELAY}) ? 1 : 0;
}

sub _commit_metric ($self, $name, $rounded) {
    my $m = $self->{+METRICS}{$name} //= {};
    $m->{last_sent} = $rounded;
    delete $m->{decrease_since};
    return;
}

sub _round_up_5 ($self, $pct) {
    # Subtract a tiny epsilon so a value already on a 5% boundary is not bumped
    # to the next bucket by floating-point noise.
    my $bucket = ceil(($pct / 5) - 1e-9);
    $bucket = 0 if $bucket < 0;
    my $r = 5 * $bucket;
    return $r > 100 ? 100 : $r;
}

sub _check_connection ($self) {
    my $sel = $self->{+SEL} or return;
    return unless $sel->can_read(0);

    my $buf = '';
    my $n   = sysread($self->{+CONN}, $buf, 4096);
    $self->stop_service if defined($n) && $n == 0;    # harness closed the connection

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
