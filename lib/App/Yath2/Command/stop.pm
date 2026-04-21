package App::Yath2::Command::stop;
use strict;
use warnings;

our $VERSION = '2.000011';

use Time::HiRes qw/sleep time/;

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

# `yath stop`: ask a running daemon to drain (finish_after_queued)
# and exit cleanly. Unlike `yath kill`, running jobs get to finish.
sub run {
    my $self = shift;

    my %opts = (timeout => 60);

    my $argv = $self->argv;
    my @rem;
    while (defined(my $a = shift @$argv)) {
        if ($a eq '--timeout') { $opts{timeout} = shift @$argv }
        elsif ($a =~ /^--timeout=(.*)$/) { $opts{timeout} = $1 }
        elsif ($a =~ /^--daemon-workdir=(.*)$/) { $opts{daemon_workdir} = $1 }
        elsif ($a eq '--daemon-workdir')        { $opts{daemon_workdir} = shift @$argv }
        elsif ($a eq '--')                      { push @rem => @$argv; last }
        else                                    { push @rem => $a }
    }
    if (@rem) {
        print STDERR "yath stop: unexpected positional argument(s): @rem\n";
        return 2;
    }

    my $spawn = eval { App::Yath2::Daemon::attach(daemon_workdir => $opts{daemon_workdir}) };
    unless ($spawn) {
        my $err = $@;
        print STDERR "yath stop: cannot attach to daemon: $err";
        return 2;
    }

    my $pid     = $spawn->pid;
    my $workdir = $spawn->workdir;

    my $resp = $spawn->finish;
    unless (ref($resp) eq 'HASH' && $resp->{ok}) {
        print STDERR "yath stop: finish request rejected: ",
            (ref($resp) eq 'HASH' ? ($resp->{error} // '(no error)') : '(no response)'),
            "\n";
        return 1;
    }

    print STDOUT "yath stop: drain requested (pid $pid, workdir $workdir)\n";

    # Wait for the daemon process to actually exit, up to --timeout.
    my $deadline = time + $opts{timeout};
    while (time < $deadline) {
        last unless kill 0, $pid;
        sleep 0.1;
    }

    if (kill 0, $pid) {
        print STDERR "yath stop: daemon still alive after ", $opts{timeout}, "s\n";
        return 1;
    }

    App::Yath2::Daemon::remove_pointers(workdir => $workdir);
    print STDOUT "yath stop: daemon exited\n";
    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::stop - Ask a running daemon to drain and exit.

=head1 DESCRIPTION

Sends a C<finish> IPC request to the discovered daemon, waits for
the process to exit, and removes the pointer files. Running jobs
finish first; new runs are rejected from the moment C<finish> is
accepted.

=cut
