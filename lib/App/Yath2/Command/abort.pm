package App::Yath2::Command::abort;
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

# `yath abort`: drop every pending test in the daemon's queue
# without tearing the daemon down. In-flight tests continue; new
# launches are stopped. Callers who want the daemon to exit
# afterwards should follow with `yath stop`.
sub run {
    my $self = shift;

    my %opts;
    my @rem;
    my $argv = $self->argv;
    while (defined(my $a = shift @$argv)) {
        if    ($a eq '--daemon-workdir')        { $opts{daemon_workdir} = shift @$argv }
        elsif ($a =~ /^--daemon-workdir=(.*)$/) { $opts{daemon_workdir} = $1 }
        elsif ($a eq '--run-id')                { $opts{run_id}         = shift @$argv }
        elsif ($a =~ /^--run-id=(.*)$/)         { $opts{run_id}         = $1 }
        elsif ($a eq '--')                      { push @rem => @$argv; last }
        else                                    { push @rem => $a }
    }
    if (@rem) {
        print STDERR "yath abort: unexpected positional argument(s): @rem\n";
        return 2;
    }

    my $spawn = eval { App::Yath2::Daemon::attach(daemon_workdir => $opts{daemon_workdir}) };
    unless ($spawn) {
        print STDERR "yath abort: cannot attach to daemon: $@";
        return 2;
    }

    my %abort_args;
    $abort_args{run_id} = $opts{run_id} if defined $opts{run_id};

    my $res = eval { $spawn->abort_runs(%abort_args) };
    unless (ref($res) eq 'HASH' && $res->{ok}) {
        print STDERR "yath abort: abort_runs failed: ",
            (ref($res) eq 'HASH' ? ($res->{error} // '(no error)') : ($@ // '(no response)')),
            "\n";
        return 1;
    }

    my $aborted = $res->{aborted} // [];
    if (@$aborted) {
        print "Aborted runs:\n";
        print "  $_\n" for @$aborted;
    }
    else {
        print "No active runs to abort.\n";
    }

    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::abort - Drop pending jobs from a running daemon.

=head1 DESCRIPTION

Sends C<abort_runs> to the discovered daemon. Every pending job in
every queued run is marked skipped; in-flight jobs keep running to
completion. Accepts an optional C<--run-id=ID> to target one run.

=cut
