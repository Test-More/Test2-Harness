package App::Yath2::Command::kill;
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

use constant IS_WIN32 => $^O eq 'MSWin32';

sub argv { $_[0]->{argv} }

sub init {
    my $self = shift;
    $self->{argv} //= [];
    return;
}

# `yath kill`: hard terminate the daemon using a TERM/INT -> KILL
# signal escalator (per IPC_AND_LOGGERS section 9.5). Use this when
# `yath stop` has failed or when the caller wants to drop in-flight
# jobs immediately rather than wait for them.
sub run {
    my $self = shift;

    my %opts = (timeout => 10);
    my @rem;
    my $argv = $self->argv;
    while (defined(my $a = shift @$argv)) {
        if    ($a eq '--daemon-workdir')        { $opts{daemon_workdir} = shift @$argv }
        elsif ($a =~ /^--daemon-workdir=(.*)$/) { $opts{daemon_workdir} = $1 }
        elsif ($a eq '--timeout')               { $opts{timeout}        = shift @$argv }
        elsif ($a =~ /^--timeout=(.*)$/)        { $opts{timeout}        = $1 }
        elsif ($a eq '--')                      { push @rem => @$argv; last }
        else                                    { push @rem => $a }
    }
    if (@rem) {
        print STDERR "yath kill: unexpected positional argument(s): @rem\n";
        return 2;
    }

    my ($pointer) = eval { App::Yath2::Daemon::discover_pointer(daemon_workdir => $opts{daemon_workdir}) };
    unless ($pointer) {
        print STDERR "yath kill: cannot find daemon pointer: $@";
        return 2;
    }

    my $pid     = $pointer->{pid};
    my $workdir = $pointer->{workdir};

    unless ($pid && kill 0, $pid) {
        print STDOUT "yath kill: daemon (pid $pid) not running; cleaning pointer files\n";
        App::Yath2::Daemon::remove_pointers(workdir => $workdir);
        return 0;
    }

    my $first_sig = IS_WIN32 ? 'INT' : 'TERM';

    # Signal escalation: first signal, poll for exit up to timeout/2
    # (giving the daemon's own Role::Service hard-stop escalator room
    # to cascade through its children), then KILL.
    kill $first_sig => $pid;
    my $half_deadline = time + ($opts{timeout} / 2);
    while (time < $half_deadline) {
        last unless kill 0, $pid;
        sleep 0.1;
    }

    if (kill 0, $pid) {
        kill KILL => $pid;
        my $deadline = time + ($opts{timeout} / 2);
        while (time < $deadline) {
            last unless kill 0, $pid;
            sleep 0.1;
        }
    }

    if (kill 0, $pid) {
        print STDERR "yath kill: daemon pid $pid still alive after KILL+grace\n";
        return 1;
    }

    App::Yath2::Daemon::remove_pointers(workdir => $workdir);
    print STDOUT "yath kill: daemon terminated (pid $pid)\n";
    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::kill - Hard-terminate a running daemon.

=head1 DESCRIPTION

Discovers the daemon pointer, signals the daemon's pid with TERM
(POSIX) or INT (Windows), and escalates to KILL if the process has
not exited within half the configured C<--timeout> (default 10s).
Cleans up pointer files afterwards.

Use C<yath stop> for a clean shutdown that lets in-flight jobs
finish; use C<yath kill> only for unresponsive daemons.

=cut
