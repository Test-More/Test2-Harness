package Test2::Harness2::Util::IPC;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak confess/;
use Errno qw/ESRCH/;

# /proc layouts we know how to parse: Linux's multi-line "PPid:" form
# and FreeBSD/DragonFlyBSD's single-line positional form. Solaris,
# NetBSD, and OpenBSD also ship procfs but with formats our parser
# doesn't handle -- on those platforms we fall through to ps even if
# /proc happens to be mounted, so we can't misread a binary status
# blob as text and return garbage.
use constant HAS_PARSEABLE_PROC =>
    ($^O eq 'linux' || $^O eq 'freebsd' || $^O eq 'dragonfly');

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    pid_is_running
    set_procname
    swap_io
    list_direct_children
};

sub pid_is_running {
    my ($pid) = @_;

    confess "A pid is required" unless $pid;

    local $!;

    return 1 if kill(0, $pid);    # Running and we have perms
    return 0 if $! == ESRCH;      # Does not exist (not running)
    return -1;                    # Running, but not ours
}

sub set_procname {
    my %params = @_;

    my $prefix = $params{prefix} // $ENV{T2_HARNESS2_PROC_PREFIX} // 'Test2-Harness2';
    my $append = $params{append} // [];
    my $set    = $params{set}    // [];

    $append = [$append] unless ref($append);
    $set    = [$set]    unless ref($set);

    my $name = join('-', (@$set ? @$set : $0), @$append);

    $name = "${prefix}-${name}" unless $name =~ m/^\Q$prefix\E-/;

    $0 = $name;
}

sub swap_io {
    my ($fh, $to) = @_;

    my $orig_fd = fileno($fh);
    croak "Could not get fd for handle" unless defined $orig_fd;

    open($fh, '>&', $to) or croak "Could not redirect fd $orig_fd: $!";

    croak "Handle does not have the expected fd (got " . fileno($fh) . ", wanted $orig_fd)"
        if fileno($fh) != $orig_fd;
}

# Enumerate the direct children of $parent. Prefers /proc/*/status
# (Linux, FreeBSD, and DragonFlyBSD when procfs is mounted) and only
# falls back to `ps -A -o pid=,ppid=` (with -e as a System-V-only
# fallback) when /proc is genuinely unavailable. Returns an empty
# list if neither source is usable. The proc and ps helpers are
# separate subs so each can be tested in isolation.
#
# We dispatch on -d '/proc' rather than on "did proc return any
# pids?" because an empty result from procfs is authoritative -- it
# means "no direct children." Falling through to ps in that case is
# unsafe: ps runs as our own direct child for the life of the pipe
# and reports itself in its output, so the ps branch would return a
# transient pid that is gone by the time the caller sees it. That
# transient then polls forever in callers that re-enumerate each
# iteration.
sub list_direct_children {
    my ($parent) = @_;

    return _list_direct_children_proc($parent) if HAS_PARSEABLE_PROC && -d '/proc';
    return _list_direct_children_ps($parent);
}

# Parse /proc/<pid>/status on any system that provides it.
#
# Linux uses a multi-line "Key:\tvalue" format with a dedicated "PPid:"
# line. FreeBSD and DragonFlyBSD procfs(5) expose a single space-
# separated line whose fields are: comm pid ppid pgid sid ... -- so the
# third field is the ppid. We slurp the file and try the Linux pattern
# first (unambiguous when present), falling back to the BSD positional
# layout.
sub _list_direct_children_proc {
    my ($parent) = @_;
    return () unless -d '/proc';

    opendir(my $dh, '/proc') or return ();
    my @kids;
    while (defined(my $ent = readdir $dh)) {
        next unless $ent =~ /\A[0-9]+\z/;
        next if $ent == $parent;

        open(my $fh, '<', "/proc/$ent/status") or next;
        local $/;
        my $content = <$fh>;
        close($fh);

        my $ppid = _parse_proc_status_ppid($content);
        push @kids => $ent + 0 if defined $ppid && $ppid == $parent;
    }
    closedir $dh;

    return @kids;
}

# Pure parser for /proc/<pid>/status content. Returns the parent pid as
# an integer, or undef if no ppid can be extracted. Split out so the
# Linux and BSD layouts can be covered by unit tests without needing
# the corresponding kernel mounted.
sub _parse_proc_status_ppid {
    my ($content) = @_;
    return undef unless defined $content && length $content;

    return $1 + 0 if $content =~ /^PPid:\s+(\d+)/m;
    return $1 + 0 if $content =~ /\A\S+\s+\d+\s+(\d+)\b/;
    return undef;
}

# Portable fallback for systems without a Linux-shaped /proc.
#
# -A is POSIX ("all processes") and is honored by every ps we target:
# GNU/Linux, macOS, all BSDs, and Solaris. -e is the System V spelling;
# it also means "all processes" on Linux/Solaris but on the BSDs it
# means "show environment" -- which succeeds silently and yields the
# wrong data -- so -A must be tried first. -e stays as a defensive
# fallback for anything very old that rejects -A.
#
# -o pid= -o ppid= suppresses headers and yields a fixed two-column
# numeric output that parses cleanly. 2>/dev/null inside the command
# string forces /bin/sh -c to handle it, so any warning ps might emit
# on an unrecognized flag never reaches our stderr. Returns an empty
# list if ps is unavailable or fails.
sub _list_direct_children_ps {
    my ($parent) = @_;

    for my $flag ('-A', '-e') {
        my $cmd = "ps $flag -o pid= -o ppid= 2>/dev/null";
        open(my $fh, '-|', $cmd) or next;

        local $/;
        my $content = <$fh>;
        close($fh);

        next unless defined $content && length $content;

        # The ps process runs as our own child for the duration of
        # the pipe and lists itself in the output. By the time we
        # close($fh) and reach this filter, ps has been reaped, so
        # kill(0, $pid) returns false for it and drops it from the
        # result. Any other transient that died between ps's snapshot
        # and here gets filtered the same way -- we can't signal or
        # reap it anymore, so the caller couldn't act on it anyway.
        return grep { kill(0, $_) } _parse_ps_pid_ppid($content, $parent);
    }

    return ();
}

# Pure parser for `ps -o pid= -o ppid=` output. Returns the pids whose
# ppid matches $parent (excluding $parent itself).
sub _parse_ps_pid_ppid {
    my ($content, $parent) = @_;
    my @kids;
    for my $line (split /\n/, $content // '') {
        next unless $line =~ /\A\s*(\d+)\s+(\d+)\s*\z/;
        push @kids => $1 + 0 if $2 == $parent && $1 != $parent;
    }
    return @kids;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::IPC - Small IPC-related helpers shared across the harness.

=head1 DESCRIPTION

A handful of low-level utilities used by the collector and other harness
processes for cross-process work.

=head1 SYNOPSIS

    use Test2::Harness2::Util::IPC qw/pid_is_running set_procname swap_io list_direct_children/;

    # Liveness check for a pid we may or may not own.
    if (my $rc = pid_is_running($child_pid)) {
        # 1  -> running and we own it
        # -1 -> running but owned by someone else
    }

    # Annotate $0 so 'ps' shows what this process is doing.
    set_procname(set => ['Collector', $child_pid]);
    set_procname(append => ['draining']);

    # Redirect a known fd onto another handle, preserving the fd number.
    open(my $log, '>>', '/tmp/out.log') or die $!;
    swap_io(\*STDOUT, $log);

    # Enumerate our direct children (subreaper orphans included on systems
    # that reparent to the nearest subreaper).
    my @kids = list_direct_children($$);

=head1 EXPORTS

=over 4

=item $bool_or_neg = pid_is_running($pid)

Returns C<1> if C<$pid> is running and we own it, C<0> if it is gone, and
C<-1> if it is running but owned by someone else.

=item set_procname(%params)

Sets C<$0> with an optional C<prefix> (default C<Test2-Harness>, overridable
via the C<T2_HARNESS_PROC_PREFIX> env var). Pass C<set =E<gt> [...]> to
replace the body, or C<append =E<gt> [...]> to append to the current C<$0>.

=item swap_io($fh, $to)

Reopens C<$fh> as a duplicate of C<$to> while preserving its file descriptor
number. Croaks if the resulting fd does not match.

=item @pids = list_direct_children($parent)

Returns the pids that are direct children of C<$parent>. Prefers
C</proc/*/status> (Linux, FreeBSD, and DragonFlyBSD when procfs is
mounted) and falls back to C<ps -e -o pid=,ppid=> when procfs is
unavailable. Returns an empty list if neither source is usable.

Intended for post-fork bookkeeping where a service acting as a child
subreaper needs to reach reparented descendants that would otherwise
be invisible to pgroup-based signalling. Not suitable for hot paths --
walking procfs or shelling out to ps is deliberately reserved for
shutdown or equivalent one-off calls.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
