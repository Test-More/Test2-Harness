package App::Yath2::Command::start;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Temp ();
use POSIX ();
use Time::HiRes qw/time/;

use Test2::Harness2::Util qw/tinysleep/;

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

# `yath start` spawns a long-running harness daemon.
#
# Unlike `yath test`, the daemon does NOT set finish_after_queued --
# it stays up waiting for runs submitted via `yath run`. The daemon
# writes a pointer file (see App::Yath2::Daemon) describing its
# workdir, pid, and IPC connection info so later attached commands
# (stop, status, ping, ...) can discover it.
#
# The `start` command stays in the foreground long enough to print
# the pointer info, then exits, leaving the daemon running. Use
# `yath spawn` to start a daemon without printing anything; use
# `yath stop` or `yath kill` to shut it down.
sub run {
    my $self = shift;

    my $argv = $self->argv;

    # Parse a couple of small options inline; the full
    # Getopt::Yath-driven surface can land later. Today we accept:
    #   --name=<bus name>   override the daemon's IPC identity
    #   --logdir=<dir>      override the logs directory
    #   --foreground / -f   keep the command attached (its Spawn
    #                       handle stays owned by the parent, so
    #                       DESTROY tears the daemon down when the
    #                       command exits -- useful for debugging)
    my %opts = (
        name       => 'harness',
        logdir     => undef,
        foreground => 0,
    );

    my @remaining;
    while (defined(my $a = shift @$argv)) {
        if ($a eq '--name') {
            $opts{name} = shift @$argv;
        }
        elsif ($a =~ /^--name=(.*)$/) {
            $opts{name} = $1;
        }
        elsif ($a eq '--logdir') {
            $opts{logdir} = shift @$argv;
        }
        elsif ($a =~ /^--logdir=(.*)$/) {
            $opts{logdir} = $1;
        }
        elsif ($a eq '--foreground' || $a eq '-f') {
            $opts{foreground} = 1;
        }
        elsif ($a eq '--') {
            push @remaining => @$argv;
            last;
        }
        else {
            push @remaining => $a;
        }
    }

    if (@remaining) {
        print STDERR "yath start: unexpected positional argument(s): @remaining\n";
        return 2;
    }

    # Each start creates a fresh tempdir workdir (per IPC_AND_LOGGERS
    # section 11.1); the daemon owns it for its lifetime.
    my $workdir = File::Temp->newdir("yath2-$$-XXXXXX", TMPDIR => 1, CLEANUP => 0);
    my $wd_path = "$workdir";

    if ($opts{foreground}) {
        # Foreground: no daemonization at all. Block until the daemon
        # exits; pointer files are removed afterwards. Ctrl-C flips a
        # graceful-finish handler.
        require Test2::Harness2;
        my $spawn = Test2::Harness2->spawn(
            workdir => $wd_path,
            name    => $opts{name},
            ($opts{logdir} ? (logdir => $opts{logdir}) : ()),
        );
        App::Yath2::Daemon::write_pointer(
            workdir   => $wd_path,
            pid       => $spawn->pid,
            ipcm_info => $spawn->ipcm_info,
            name      => $opts{name},
        );

        print STDOUT "yath daemon started\n";
        print STDOUT "  pid:     ", $spawn->pid, "\n";
        print STDOUT "  name:    ", $opts{name}, "\n";
        print STDOUT "  workdir: $wd_path\n";

        local $SIG{INT}  = sub { eval { $spawn->finish }; 0 };
        local $SIG{TERM} = sub { eval { $spawn->finish }; 0 };

        $spawn->wait;
        App::Yath2::Daemon::remove_pointers(workdir => $wd_path);
        print STDOUT "yath daemon exited\n";
        return 0;
    }

    # Default (detached) mode: classic double-fork daemonization.
    #
    # We cannot let Test2::Harness2->spawn fork the daemon directly
    # from this command process because the daemon would inherit
    # every fd we hold open -- including the parent's STDOUT pipe
    # when the caller ran us in a pipeline (`yath start | foo`).
    # That inherited pipe would stay open until the daemon exits,
    # which makes the pipeline reader hang on EOF forever.
    #
    # Instead we fork an intermediary daemonizer. The intermediary
    # closes all inherited stdio, starts the harness service, writes
    # the pointer file, and exits. The original command process
    # waits for the intermediary, then reads the pointer file and
    # prints the banner before it exits -- no shared fds with the
    # eventual daemon.
    pipe(my $pipe_r, my $pipe_w) or die "pipe: $!";

    my $child_pid = fork // die "fork: $!";
    if (!$child_pid) {
        close $pipe_r;
        _detach_stdio();

        require Test2::Harness2;
        my $spawn = Test2::Harness2->spawn(
            workdir => $wd_path,
            name    => $opts{name},
            ($opts{logdir} ? (logdir => $opts{logdir}) : ()),
        );
        App::Yath2::Daemon::write_pointer(
            workdir   => $wd_path,
            pid       => $spawn->pid,
            ipcm_info => $spawn->ipcm_info,
            name      => $opts{name},
        );

        # Signal the original command that the pointer is in place.
        print {$pipe_w} $spawn->pid, "\n";
        close $pipe_w;

        # Detach from the harness spawn handle (so its DESTROY on
        # intermediary exit does not kill the daemon) and exit.
        $spawn->detach;
        POSIX::_exit(0);
    }

    # Parent: wait for the intermediary to finish writing the pointer
    # (evidenced by the pipe being readable / closed), then read the
    # pointer file and print the banner.
    close $pipe_w;
    my $daemon_pid = <$pipe_r>;
    close $pipe_r;
    waitpid($child_pid, 0);

    unless (defined $daemon_pid && $daemon_pid =~ /^\d+/) {
        print STDERR "yath start: daemonizer did not report a pid\n";
        return 1;
    }
    chomp $daemon_pid;

    print STDOUT "yath daemon started\n";
    print STDOUT "  pid:     $daemon_pid\n";
    print STDOUT "  name:    ", $opts{name}, "\n";
    print STDOUT "  workdir: $wd_path\n";

    return 0;
}

# Re-open STDIN, STDOUT, STDERR onto /dev/null so anything the
# daemon inherits via fork does not hold a parent-side pipe / tty
# open. Called before Test2::Harness2->spawn() in the default
# (non-foreground) start path.
sub _detach_stdio {
    open(STDIN,  '<', '/dev/null') or die "re-open STDIN from /dev/null: $!";
    open(STDOUT, '>', '/dev/null') or die "re-open STDOUT to /dev/null: $!";
    open(STDERR, '>', '/dev/null') or die "re-open STDERR to /dev/null: $!";
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::start - Start a long-running yath harness daemon.

=head1 SYNOPSIS

    yath start
    yath start --name=my-daemon
    yath start --foreground

=head1 DESCRIPTION

C<yath start> spawns a long-running harness service and writes a
daemon pointer at C<< $workdir/daemon.json >> plus a discovery hint at
C<< ./.yath-daemon.json >> so attached commands can find it. The
command prints the daemon's pid, name, and workdir, then detaches.

=head1 OPTIONS

=over 4

=item --name=NAME

Override the daemon's IPC bus identity. Default: C<harness>.

=item --logdir=DIR

Override the logs directory. Defaults to C<< $workdir/logs >>.

=item --foreground / -f

Keep the command attached to the daemon; it blocks until the daemon
exits and then cleans up pointer files. Useful for debugging; the
default mode detaches.

=back

=head1 EXIT CODES

=over 4

=item * 0 on successful daemon start (or on clean foreground exit).

=item * 2 on argument parse failure or unexpected positional args.

=back

=cut
