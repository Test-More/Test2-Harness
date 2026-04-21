package App::Yath2::Command::spawn;
use strict;
use warnings;

our $VERSION = '2.000011';

use File::Temp ();
use POSIX ();

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

# `yath spawn` is the silent cousin of `yath start`. It starts a
# daemon identically (same workdir + pointer file) but prints only
# minimum information and always detaches. 'start' is the user-facing
# command; 'spawn' is suitable for scripted launches.
sub run {
    my $self = shift;

    my $argv = $self->argv;

    my %opts = (name => 'harness', logdir => undef);

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
        elsif ($a eq '--') {
            push @remaining => @$argv;
            last;
        }
        else {
            push @remaining => $a;
        }
    }

    if (@remaining) {
        print STDERR "yath spawn: unexpected positional argument(s): @remaining\n";
        return 2;
    }

    my $workdir = File::Temp->newdir("yath2-$$-XXXXXX", TMPDIR => 1, CLEANUP => 0);
    my $wd_path = "$workdir";

    # Double-fork daemonization -- same rationale as start.pm.
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

        print {$pipe_w} $spawn->pid, "\n";
        close $pipe_w;

        $spawn->detach;
        POSIX::_exit(0);
    }

    close $pipe_w;
    my $daemon_pid = <$pipe_r>;
    close $pipe_r;
    waitpid($child_pid, 0);

    unless (defined $daemon_pid && $daemon_pid =~ /^\d+/) {
        print STDERR "yath spawn: daemonizer did not report a pid\n";
        return 1;
    }
    chomp $daemon_pid;

    print STDOUT "pid=$daemon_pid workdir=$wd_path\n";

    return 0;
}

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

App::Yath2::Command::spawn - Silent daemon launcher (for scripted use).

=head1 DESCRIPTION

C<yath spawn> is the machine-friendly cousin of C<yath start>. It
starts a daemon with the same pointer-file semantics, prints a single
C<pid=... workdir=...> line on stdout, and detaches. Use C<yath start>
when a human is driving; use C<yath spawn> from scripts.

=head1 EXIT CODES

=over 4

=item * 0 on successful daemon start.

=item * 2 on argument parse failure or unexpected positional args.

=back

=cut
