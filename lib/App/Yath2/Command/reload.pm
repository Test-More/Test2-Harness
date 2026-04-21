package App::Yath2::Command::reload;
use strict;
use warnings;

our $VERSION = '2.000011';

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

# `yath reload`: ask the daemon to reload its preload resources.
# The actual reload logic is currently scaffolded under Stage 9
# (ChangeWatcher + Reloader roles) and will expand once preload
# reload integration lands; for now this command sends the signal
# so the resource layer can begin to act on it.
sub run {
    my $self = shift;

    my %opts;
    my @rem;
    my $argv = $self->argv;
    while (defined(my $a = shift @$argv)) {
        if    ($a eq '--daemon-workdir')        { $opts{daemon_workdir} = shift @$argv }
        elsif ($a =~ /^--daemon-workdir=(.*)$/) { $opts{daemon_workdir} = $1 }
        elsif ($a eq '--')                      { push @rem => @$argv; last }
        else                                    { push @rem => $a }
    }
    if (@rem) {
        print STDERR "yath reload: unexpected positional argument(s): @rem\n";
        return 2;
    }

    my $spawn = eval { App::Yath2::Daemon::attach(daemon_workdir => $opts{daemon_workdir}) };
    unless ($spawn) {
        print STDERR "yath reload: cannot attach to daemon: $@";
        return 2;
    }

    my $res = eval { $spawn->reload_preloads };
    unless (ref($res) eq 'HASH' && $res->{ok}) {
        print STDERR "yath reload: reload_preloads failed: ",
            (ref($res) eq 'HASH' ? ($res->{error} // '(no error)') : ($@ // '(no response)')),
            "\n";
        return 1;
    }

    my $reloaded = $res->{reloaded} // [];
    if (@$reloaded) {
        print "Reload requested for preload resources: ", join(', ', @$reloaded), "\n";
    }
    else {
        print "No preload resources to reload.\n";
    }

    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::reload - Ask a daemon to reload its preload resources.

=head1 DESCRIPTION

Sends C<reload_preloads> to the discovered daemon. The daemon
iterates its preload resources and invokes each one's
C<request_reload> hook (when present). Until Stage 9's reload
integration is complete the hook is a no-op scaffold; the command
still exits cleanly.

=cut
