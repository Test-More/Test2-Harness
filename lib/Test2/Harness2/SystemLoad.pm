package Test2::Harness2::SystemLoad;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Time::HiRes qw/time/;

use Object::HashBase qw{
    <os
    +prev_cpu
    +ncpu
    +mem_total
    +pagesize
    +bsd_no_mem
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::SystemLoad - Sample system CPU and memory load.

=head1 DESCRIPTION

A small, stateless-ish primitive that reads current CPU utilization, memory use,
and load average. It holds only the previous CPU reading so that C<sample> can
compute a utilization percentage from the delta between two readings.

CPU percentage is only meaningful across a B<consistent> interval, so the
intended caller is L<Test2::Harness2::Service::Sampler>, which calls C<sample>
on a fixed cadence. The first C<sample> has no previous reading and reports
C<cpu_pct> as C<undef> (a baseline); every later call reports a real percentage
over the interval since the prior call.

Supported platforms: Linux (via C</proc>) and the BSDs / DragonFly (via
C<sysctl>). On BSD, C<mem_available> may be C<undef> when the flavor does not
expose the page counters; CPU and load average work everywhere supported.
Elsewhere the numeric fields are C<undef>.

=head1 SYNOPSIS

    my $src  = Test2::Harness2::SystemLoad->new;
    my $snap = $src->sample;    # baseline (cpu_pct undef)
    ... wait a fixed interval ...
    my $snap = $src->sample;    # { cpu_pct, ncpu, load_avg, mem_* , stamp }

=head1 ATTRIBUTES

=over 4

=item os

The detected platform family: C<linux>, C<bsd>, or C<unsupported>. Defaults from
C<$^O>; settable for testing.

=back

=cut

sub init ($self) {
    $self->{+OS} //= $self->_detect_os;
    return;
}

# Pure platform classification of $^O.
sub _detect_os ($self) {
    return 'linux' if $^O eq 'linux';
    return 'bsd'   if $^O =~ /bsd|dragonfly/i;
    return 'unsupported';
}

=head1 PUBLIC METHODS

=cut

=over 4

=item $snapshot = $src->sample

Take one reading and return a snapshot hashref:

    {
        stamp         => <Time::HiRes seconds>,
        cpu_pct       => <0..100 busy percent, or undef on the first sample>,
        ncpu          => <logical cpu count, or undef>,
        load_avg      => [<1m>, <5m>, <15m>],   # may be empty
        mem_total     => <bytes, or undef>,
        mem_available => <bytes, or undef>,
        mem_used      => <bytes, or undef>,
        mem_pct       => <0..100 used percent, or undef>,
    }

=back

=cut

sub sample ($self) {
    my $cpu_pct = $self->_cpu_pct;
    my $mem     = $self->_mem;

    my $total = $mem->{total};
    my $avail = $mem->{available};
    my $used  = (defined $total && defined $avail) ? $total - $avail        : undef;
    my $pct   = (defined $used  && $total)         ? (100 * $used / $total) : undef;

    return {
        stamp         => time,
        cpu_pct       => $cpu_pct,
        ncpu          => $self->_ncpu,
        load_avg      => $self->_load_avg,
        mem_total     => $total,
        mem_available => $avail,
        mem_used      => $used,
        mem_pct       => $pct,
    };
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $os = $self->_detect_os

Classify C<$^O> into C<linux> / C<bsd> / C<unsupported>.

=item $pct = $self->_cpu_pct

Read raw CPU counters, fold against the previous reading, and return the busy
percentage (C<undef> when there is no previous reading or no counters).

=item ($idle, $total) = $self->_read_cpu

Platform read of cumulative CPU time: total of all states and the idle portion.
Returns an empty list when unavailable.

=item $n = $self->_ncpu

Logical CPU count (cached).

=item \@avg = $self->_load_avg

The 1 / 5 / 15 minute load averages (possibly empty).

=item \%mem = $self->_mem

C<< {total, available} >> in bytes; either may be missing.

=item $n = $self->_sysctl_int($name)

Read a sysctl value and return the first integer in it, or C<undef>.

=item $content = $self->_read_file($path)

Slurp a file, or C<undef> on failure. Test seam.

=item $value = $self->_read_sysctl($name)

Return the trimmed value of C<sysctl -n $name>, or C<undef>. Test seam.

=back

=cut

sub _cpu_pct ($self) {
    my ($idle, $total) = $self->_read_cpu;
    return undef unless defined $total;

    my $prev = $self->{+PREV_CPU};
    $self->{+PREV_CPU} = {idle => $idle, total => $total};

    return undef unless $prev;    # first reading: baseline only

    my $dt = $total - $prev->{total};
    my $di = $idle - $prev->{idle};
    return undef if $dt <= 0;

    my $pct = 100 * ($dt - $di) / $dt;
    $pct = 0   if $pct < 0;
    $pct = 100 if $pct > 100;
    return $pct;
}

sub _read_cpu ($self) {
    my $os = $self->{+OS};

    if ($os eq 'linux') {
        my $stat   = $self->_read_file('/proc/stat') // return ();
        my ($line) = $stat =~ /^cpu\s+(.*)$/m or return ();
        my @f      = split /\s+/, $line;    # user nice system idle iowait irq softirq steal guest guest_nice
        return () unless @f >= 5;
        # guest / guest_nice (fields 8,9) are already included in user / nice, so
        # never add them separately; sum only fields 0..7.
        my $idle  = ($f[3] // 0) + ($f[4] // 0);    # idle + iowait
        my $total = 0;
        $total += ($_ // 0) for @f[0 .. 7];
        return ($idle, $total);
    }

    if ($os eq 'bsd') {
        my $raw = $self->_read_sysctl('kern.cp_time') // return ();
        my @t   = $raw =~ /(\d+)/g;                                   # 5 (FreeBSD/NetBSD) or 6 (OpenBSD) states
        return () unless @t >= 2;
        my $idle  = $t[-1];                                           # idle is always the last state
        my $total = 0;
        $total += $_ for @t;
        return ($idle, $total);
    }

    return ();
}

sub _ncpu ($self) {
    return $self->{+NCPU} if defined $self->{+NCPU};

    my $os = $self->{+OS};
    my $n;

    if ($os eq 'linux') {
        my $stat = $self->_read_file('/proc/stat');
        $n = () = ($stat // '') =~ /^cpu\d+\s/mg;
    }
    elsif ($os eq 'bsd') {
        my $v = $self->_read_sysctl('hw.ncpu');
        $n = $1 if defined $v && $v =~ /(\d+)/;
    }

    return $self->{+NCPU} = ($n || undef);
}

sub _load_avg ($self) {
    my $os = $self->{+OS};

    if ($os eq 'linux') {
        my $la = $self->_read_file('/proc/loadavg') // return [];
        my @v  = $la =~ /([0-9]+\.[0-9]+)/g;
        return [map { $_ + 0 } @v[0 .. 2]] if @v >= 3;
        return [];
    }

    if ($os eq 'bsd') {
        my $la = $self->_read_sysctl('vm.loadavg') // return [];
        my @v  = $la =~ /([0-9]+\.[0-9]+)/g;                       # "{ 0.12 0.05 0.01 }" or "0.12 0.05 0.01"
        return [map { $_ + 0 } @v[0 .. 2]] if @v >= 3;
        return [];
    }

    return [];
}

sub _mem ($self) {
    my $os = $self->{+OS};

    if ($os eq 'linux') {
        my $mi = $self->_read_file('/proc/meminfo') // return {};
        my %kb;
        while ($mi =~ /^(\w+):\s+(\d+)\s*kB$/mg) { $kb{$1} = $2 }
        my $total = $kb{MemTotal};
        my $avail = $kb{MemAvailable} // ((($kb{MemFree} // 0) + ($kb{Buffers} // 0) + ($kb{Cached} // 0)) || undef);
        return {
            total     => defined $total ? $total * 1024 : undef,
            available => defined $avail ? $avail * 1024 : undef,
        };
    }

    if ($os eq 'bsd') {
        my $total = $self->{+MEM_TOTAL} //= do {
            my $v = $self->_read_sysctl('hw.physmem');
            (defined $v && $v =~ /(\d+)/) ? $1 : undef;
        };

        # mem_available is flavor-specific; only FreeBSD-style vm.stats page
        # counters are attempted. Cache a negative result so we stop shelling
        # out for counters that do not exist on this host.
        return {total => $total, available => undef} if $self->{+BSD_NO_MEM};

        my $pagesize = $self->{+PAGESIZE} //= do {
            my $v = $self->_read_sysctl('hw.pagesize');
            (defined $v && $v =~ /(\d+)/) ? $1 : 4096;
        };

        my $free     = $self->_sysctl_int('vm.stats.vm.v_free_count');
        my $inactive = $self->_sysctl_int('vm.stats.vm.v_inactive_count');
        my $cache    = $self->_sysctl_int('vm.stats.vm.v_cache_count');

        unless (defined $free) {
            $self->{+BSD_NO_MEM} = 1;
            return {total => $total, available => undef};
        }

        my $pages = $free + ($inactive // 0) + ($cache // 0);
        return {total => $total, available => $pages * $pagesize};
    }

    return {};
}

sub _sysctl_int ($self, $name) {
    my $v = $self->_read_sysctl($name);
    return undef unless defined $v && $v =~ /(\d+)/;
    return $1;
}

sub _read_file ($self, $path) {
    open(my $fh, '<', $path) or return undef;
    local $/;
    my $content = <$fh>;
    close($fh);
    return $content;
}

sub _read_sysctl ($self, $name) {
    my $out = `sysctl -n $name 2>/dev/null`;
    return undef unless defined $out && length $out;
    $out =~ s/^\s+//;
    $out =~ s/\s+$//;
    return length $out ? $out : undef;
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
