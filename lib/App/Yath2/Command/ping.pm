package App::Yath2::Command::ping;
use strict;
use warnings;

our $VERSION = '2.000011';

use Time::HiRes qw/time/;

use App::Yath2::Daemon;

use Object::HashBase qw{
    <script
    <config
    <user_config
};

sub argv { $_[0]->{argv} }

sub init {
    my $self = shift;
    $self->{argv} //= [];
    return;
}

# `yath ping`: cheap liveness check. One round-trip to the daemon's
# ping handler; prints the round-trip time on success.
sub run {
    my $self = shift;

    my %opts = (count => 1);
    my @rem;
    my $argv = $self->argv;
    while (defined(my $a = shift @$argv)) {
        if    ($a eq '--daemon-workdir')        { $opts{daemon_workdir} = shift @$argv }
        elsif ($a =~ /^--daemon-workdir=(.*)$/) { $opts{daemon_workdir} = $1 }
        elsif ($a eq '--count' || $a eq '-n')   { $opts{count}          = shift @$argv }
        elsif ($a =~ /^--count=(.*)$/)          { $opts{count}          = $1 }
        elsif ($a eq '--')                      { push @rem => @$argv; last }
        else                                    { push @rem => $a }
    }
    if (@rem) {
        print STDERR "yath ping: unexpected positional argument(s): @rem\n";
        return 2;
    }

    my $spawn = eval { App::Yath2::Daemon::attach(daemon_workdir => $opts{daemon_workdir}) };
    unless ($spawn) {
        print STDERR "yath ping: cannot attach to daemon: $@";
        return 2;
    }

    my $count = $opts{count} || 1;
    my $fails = 0;
    for my $i (1 .. $count) {
        my $t0 = time;
        my $res = eval { $spawn->ping };
        my $dt  = time - $t0;
        if (ref($res) eq 'HASH' && $res->{ok}) {
            printf "ping %d ok pid=%s name=%s rtt=%.4fs\n",
                $i, ($res->{pong} // '?'), ($res->{name} // '?'), $dt;
        }
        else {
            print STDERR "ping $i failed: ", ($@ // '(no error)'), "\n";
            $fails++;
        }
    }

    return $fails ? 1 : 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::ping - Liveness check against a running daemon.

=head1 DESCRIPTION

Single round-trip C<ping> IPC request against the discovered daemon.
Supports C<--count N> / C<-n N> to repeat the check. Exits 0 on
successful ping(s), 1 if any ping failed, 2 on attach failure.

=cut
