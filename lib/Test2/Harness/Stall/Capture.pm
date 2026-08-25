package Test2::Harness::Stall::Capture;
use strict;
use warnings;

our $VERSION = '1.000177';

use Carp qw/croak/;
use Config qw/%Config/;
use File::Spec();
use Time::HiRes qw/sleep time/;

use Test2::Harness::Util::HashBase qw{
    <workdir <stall_dir
    <root_pid
};

# Rounds of per-process sampling, and the gap between them. More than one
# sample is what separates a process wedged on a single operation from one
# looping without progress, which is the first question any analysis asks.
use constant ROUNDS    => 3;
use constant ROUND_GAP => 2;
use constant SIG_WAIT  => 1;
use constant MAX_FIELD => 8192;

# The whole capture blocks the render loop. Nothing is being rendered during a
# stall, but keep the bound small enough that a benign report is not felt.
use constant SHELL_SECONDS => 1;

sub init {
    my $self = shift;

    croak "You must specify a workdir" unless defined $self->{+WORKDIR};

    $self->{+STALL_DIR} //= File::Spec->catdir($self->{+WORKDIR}, 'stall');
    $self->{+ROOT_PID}  //= $$;

    return;
}

sub have_proc { return ($^O eq 'linux' && -d '/proc') ? 1 : 0 }

sub read_proc {
    my $self = shift;
    my ($pid, $what) = @_;

    my $path = File::Spec->catfile('/proc', $pid, $what);

    open(my $fh, '<', $path) or return;
    local $/;
    my $out = <$fh>;
    close($fh);

    # /proc/PID/syscall and friends are gated on ptrace permission. When it is
    # denied the open succeeds and the read comes back empty, so the read is
    # what has to be checked, not the open.
    return unless defined $out && length $out;

    $out =~ s/\0/ /g;
    $out =~ s/\s+\z//;

    return substr($out, 0, MAX_FIELD);
}

sub list_fds {
    my $self = shift;
    my ($pid) = @_;

    my $dir = File::Spec->catdir('/proc', $pid, 'fd');

    opendir(my $dh, $dir) or return;
    my @fds = grep { m/^\d+$/ } readdir($dh);
    closedir($dh);

    my %out;
    for my $fd (sort { $a <=> $b } @fds) {
        my $target = readlink(File::Spec->catfile($dir, $fd)) // next;
        $out{$fd} = $target;
    }

    return \%out;
}

sub proc_snapshot {
    my $self = shift;
    my ($pid) = @_;

    my %out = (pid => $pid);

    unless ($self->have_proc) {
        # Not the same as gone: the process is alive, we simply cannot see it.
        $out{unavailable} = "no /proc on $^O";
        return \%out;
    }

    my $status = $self->read_proc($pid, 'status');
    unless (defined $status) {
        $out{gone} = 1;
        return \%out;
    }

    for my $field (qw/Name State PPid Threads SigBlk SigIgn SigCgt/) {
        next unless $status =~ m/^\Q$field\E:\s*(.*)$/m;
        $out{lc($field)} = $1;
    }

    $out{cmdline} = $self->read_proc($pid, 'cmdline');
    $out{wchan}   = $self->read_proc($pid, 'wchan');
    $out{syscall} = $self->read_proc($pid, 'syscall');
    $out{stack}   = $self->read_proc($pid, 'stack');
    $out{fds}     = $self->list_fds($pid);

    return \%out;
}

# Every descendant of the runner, so a wedged process that is not on the
# whitelist still appears in the report even though it is never signalled.
sub all_pids {
    my $self = shift;

    opendir(my $dh, '/proc') or return;
    my @pids = grep { m/^\d+$/ } readdir($dh);
    closedir($dh);

    return \@pids;
}

sub process_tree {
    my $self = shift;
    my ($root) = @_;

    return unless $root && $self->have_proc;

    my $pids = $self->all_pids or return;

    my %parent;
    for my $pid (@$pids) {
        my $stat = $self->read_proc($pid, 'stat') or next;

        # comm can contain spaces and parens, so parse after the last ')'.
        my $tail = substr($stat, rindex($stat, ')') + 1);
        next unless $tail =~ m/^\s+\S+\s+(\d+)/;
        $parent{$pid} = $1;
    }

    my %keep  = ($root => 1);
    my $added = 1;
    while ($added) {
        $added = 0;
        for my $pid (keys %parent) {
            next if $keep{$pid};
            next unless $keep{$parent{$pid}};
            $keep{$pid} = 1;
            $added++;
        }
    }

    return [sort { $a <=> $b } keys %keep];
}

sub system_snapshot {
    my $self = shift;

    my %out;

    return \%out unless $self->have_proc;

    for my $file (qw/loadavg meminfo locks/) {
        open(my $fh, '<', "/proc/$file") or next;
        local $/;
        my $content = <$fh>;
        close($fh);
        next unless defined $content;

        # meminfo is long and only its head is ever useful here.
        if ($file eq 'meminfo') {
            my @lines = split /\n/, $content;
            $content = join("\n", @lines[0 .. ($#lines < 8 ? $#lines : 8)]);
        }

        $out{$file} = substr($content, 0, MAX_FIELD);
    }

    return \%out;
}

sub workdir_filesystem {
    my $self = shift;

    return unless $self->have_proc;

    my $seconds = SHELL_SECONDS;
    my $dir     = $self->{+WORKDIR};
    $dir =~ s/'/'\\''/g;

    # Bounded, and quoted: a hung mount is a plausible cause of the stall being
    # diagnosed, and an unbounded df against one would hang the render loop.
    my $out = `timeout $seconds df -PT '$dir' 2>/dev/null`;
    return unless defined $out && length $out;

    return substr($out, 0, MAX_FIELD);
}

sub strace {
    my $self = shift;
    my ($pid) = @_;

    # Usually denied. Yama checks the tracer against the target's ancestry and
    # strace is a freshly exec'd process, so it is never an ancestor of the
    # scheduler no matter who launches it. Kept because some CI containers run
    # with ptrace_scope=0 or CAP_SYS_PTRACE; /proc/PID/syscall and wchan answer
    # the same question when it is not available.
    my $seconds = SHELL_SECONDS;
    my $out     = `timeout $seconds strace -qq -p $pid -e trace=all 2>&1`;

    return unless defined $out && length $out;

    return substr($out, 0, MAX_FIELD);
}

sub read_traces {
    my $self = shift;

    my $dir = $self->{+STALL_DIR};
    opendir(my $dh, $dir) or return {};
    my @files = grep { m/^stack-\d+-\d+\.txt$/ } readdir($dh);
    closedir($dh);

    my %out;
    for my $file (@files) {
        my $path = File::Spec->catfile($dir, $file);

        open(my $fh, '<', $path) or next;
        local $/;
        my $content = <$fh>;
        close($fh);
        next unless defined $content;
        $out{$file} = substr($content, 0, MAX_FIELD);

        # Consume them, so the next report shows only its own traces. Filtering
        # by round number instead would need every process to have been
        # signalled in every round, which a stage that comes up late has not.
        unlink($path);
    }

    return \%out;
}

# Bit for a signal number in the SigCgt / SigIgn masks of /proc/PID/status.
sub _sig_bit { return 1 << ($_[1] - 1) }

# Not a constant: SIGUSR1 is 10 on x86 but 16 on MIPS and 30 on SPARC, and
# have_proc only narrows this to Linux.
my $USR1;

sub usr1_number {
    return $USR1 //= do {
        my @names = split ' ', $Config{sig_name};
        my @nums  = split ' ', $Config{sig_num};

        my %map;
        @map{@names} = @nums;

        $map{USR1} // 10;
    };
}

sub catches_usr1 {
    my $self = shift;
    my ($proc) = @_;

    my $mask = $proc->{sigcgt} or return 0;
    return 0 unless $mask =~ m/^[0-9a-fA-F]+$/;

    # The field is a 64 bit mask written as hex, which overflows hex() on a 32
    # bit perl. Only the low word holds the ordinary signals, and SIGUSR1 is
    # one of them.
    return (hex(substr($mask, -8)) & $self->_sig_bit($self->usr1_number)) ? 1 : 0;
}

sub kill_pid { return kill('USR1', $_[1]) }

sub signal_pids {
    my $self = shift;
    my ($pids, $procs) = @_;

    $procs //= {};

    my @sent;
    for my $pid (@$pids) {

        # Never a process group. A negative pid here would signal one, and
        # SIGUSR1's default action is to terminate.
        next unless $pid && $pid > 0;

        # Only a process that actually installed the handler. A test job sheds
        # it when the runner restores the original %SIG, so a signal there
        # kills a running test; and a pid recorded earlier may since have
        # exited and been recycled by something unrelated. SigCgt answers both
        # exactly, and proc_snapshot already collected it moments ago.
        if ($self->have_proc) {
            my $proc = $procs->{$pid};
            next unless $proc && !$proc->{gone};
            next unless $self->catches_usr1($proc);
        }

        push @sent => $pid if $self->kill_pid($pid);
    }

    return \@sent;
}

sub collect {
    my $self = shift;
    my ($info) = @_;

    my $whitelist = $info->{harness_pids} // [];

    mkdir($self->{+STALL_DIR});

    my %out = (
        time         => time,
        tier         => $info->{tier},
        idle         => $info->{idle},
        threshold    => $info->{threshold},
        pending      => $info->{pending},
        running      => $info->{running},
        round        => $info->{round},
        harness_pids => $whitelist,
        have_proc    => $self->have_proc,
        system       => $self->system_snapshot,
        filesystem   => $self->workdir_filesystem,
        tree         => $self->process_tree($self->{+ROOT_PID}),
        samples      => [],
    );

    my $tree = $out{tree} // $whitelist;

    for my $round (1 .. ROUNDS) {
        # Collect before signalling. A process in an uninterruptible syscall
        # never runs its handler, and that is exactly the case most in need of
        # description, so the external evidence must not depend on a reply.
        my %sample = (round => $round, procs => {});
        my %seen;
        $sample{procs}->{$_} = $self->proc_snapshot($_)
            for grep { !$seen{$_}++ } @$tree, @$whitelist;

        $sample{strace} = $self->strace($info->{scheduler_pid})
            if $round == 1 && $info->{scheduler_pid};

        $sample{signalled} = $self->signal_pids($whitelist, $sample{procs});

        push @{$out{samples}} => \%sample;

        sleep(ROUND_GAP) if $round < ROUNDS;
    }

    # Whatever arrived. A missing trace is itself evidence: no stack plus an
    # uninterruptible state says the process could not run Perl at all.
    sleep(SIG_WAIT);
    $out{traces} = $self->read_traces();

    return \%out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Stall::Capture - Collect evidence about a stalled run from
outside the stuck processes.

=head1 DESCRIPTION

Gathers everything obtainable without the stuck process's cooperation, then
asks each harness process for its Perl call stack.

The order matters. A process in an uninterruptible syscall, or in XS that
retries C<EINTR>, never runs a signal handler, so external evidence must not
depend on a reply. A missing stack is itself a finding: no stack plus an
uninterruptible state says the process could not run Perl at all.

Each report samples several times a few seconds apart. Frames and syscalls that
move between samples mean a loop making no progress; frames that do not mean
the process is stuck on one operation. That distinction is the first question
any analysis asks.

C<strace> is attempted and usually denied: Yama checks the tracer against the
target's ancestry, and C<strace> is a freshly exec'd process, so it is never an
ancestor of the scheduler. It is kept for hosts that permit it, and
C</proc/PID/wchan> and C</proc/PID/syscall> answer the same question when it
does not. Every shell-out is bounded, because this blocks the caller.

Everything here is Linux-specific and degrades to the state dump and the stack
traces elsewhere.

=head1 SYNOPSIS

    use Test2::Harness::Stall::Capture;

    my $capture = Test2::Harness::Stall::Capture->new(
        workdir  => $workdir,
        root_pid => $$,
    );

    my $bundle = $capture->collect(\%info);

=head1 ATTRIBUTES

=over 4

=item $string = $capture->workdir()

The run's working directory.

=item $string = $capture->stall_dir()

Where the signalled processes leave their stack traces. Defaults to C<stall>
inside the working directory.

=item $int = $capture->root_pid()

Root of the process tree to describe. Defaults to the current process.

=back

=head1 PUBLIC METHODS

=over 4

=item $hashref = $capture->collect(\%info)

Runs the whole capture and returns the bundle. C<%info> carries what the
detector observed, and the pids to signal as C<harness_pids>.

=item $bool = $capture->have_proc()

True on a platform where C</proc> can be read.

=item $hashref = $capture->proc_snapshot($pid)

State, wait channel, syscall, command line, caught signals and open files for
one process.

=item $string = $capture->read_proc($pid, $what)

One C</proc/PID> file, or nothing. Some of these are gated on ptrace
permission, and when it is refused the open succeeds and the read comes back
empty -- so the read is what must be checked.

=item $hashref = $capture->list_fds($pid)

File descriptor number to what it points at.

=item $arrayref = $capture->process_tree($pid)

Every descendant of a pid, including it.

=item $arrayref = $capture->all_pids()

Every pid on the system, or nothing where there is no C</proc>.

=item $bool = $capture->kill_pid($pid)

Sends C<SIGUSR1> to one pid.

=item $arrayref = $capture->signal_pids(\@pids, \%procs)

Sends C<SIGUSR1> to each pid that this round's snapshot shows alive and
catching that signal, and returns those actually signalled. A process that did
not install the handler is never signalled, because the default action would
terminate it. Where there is no C</proc> that check cannot be made and every
positive pid in the list is signalled. Never signals a process group.

=item $bool = $capture->catches_usr1(\%proc)

Whether a snapshot shows the process catching C<SIGUSR1>, read from C<SigCgt>.

=item $int = $capture->usr1_number()

The local signal number for C<SIGUSR1>.

=item $hashref = $capture->system_snapshot()

Load, memory and the lock table.

=item $string = $capture->workdir_filesystem()

Filesystem type and free space for the working directory.

=item $string = $capture->strace($pid)

Best-effort C<strace> output, or its refusal.

=item $hashref = $capture->read_traces()

Stack traces written since the last call, keyed by filename. Consumes them.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness/>.

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
