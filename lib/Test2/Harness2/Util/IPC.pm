package Test2::Harness2::Util::IPC;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak confess/;
use Errno qw/ESRCH/;
use File::ShareDir ();

# /proc layouts we know how to parse: Linux's multi-line "PPid:" form
# and FreeBSD/DragonFlyBSD's single-line positional form. Solaris,
# NetBSD, and OpenBSD also ship procfs but with formats our parser
# doesn't handle -- on those platforms we fall through to ps even if
# /proc happens to be mounted, so we can't misread a binary status
# blob as text and return garbage.
use constant HAS_PARSEABLE_PROC => ($^O eq 'linux' || $^O eq 'freebsd' || $^O eq 'dragonfly');

# IPC::Manager protocol used as the default for harness IPC. The
# ConnectionUnix driver gives us per-peer SOCK_STREAM connections
# with optional listen sockets, so transient peers (collectors, the
# parent-side spawn handle) can skip listening while services keep
# listen=1 to accept inbound traffic.
use constant IPC_DEFAULT_PROTOCOL => 'IPC::Manager::Client::ConnectionUnix';

# Zstd compression level. 3 is Compress::Zstd's library default and
# the same value JSON::Zstd uses when nothing is supplied; we set it
# explicitly so the spec is self-describing and a future tuning
# change is a one-line edit here.
use constant IPC_DEFAULT_ZSTD_LEVEL => 3;

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    pid_is_running
    set_procname
    start_process
    swap_io
    list_direct_children
    ipc_default_protocol
    ipc_default_serializer
    ipc_default_spawn_args
    ipc_default_connect_args
    ipc_zstd_dict_path
};

sub ipc_default_protocol { IPC_DEFAULT_PROTOCOL }

# Path to the install-shipped zstd compression dictionary
# (share/other/zstd.dict, exposed via File::ShareDir). Returns undef
# when the dictionary is unavailable; the serializer then falls back
# to dictless compression. Both peers must resolve the same path
# with identical content -- File::ShareDir guarantees that for any
# install that ships the share file.
sub ipc_zstd_dict_path {
    my $dict = eval { File::ShareDir::dist_file('Test2-Harness2', 'other/zstd.dict') };
    return undef unless defined $dict && -f $dict && -r _;
    return $dict;
}

# Default serializer spec for harness IPC: JSON::Zstd at level 3
# with the install-shipped dictionary. The ['Class', %args] form
# tells IPC::Manager to construct one configured instance and share
# it across peers (see IPC::Manager::Serializer::JSON::Zstd).
sub ipc_default_serializer {
    my $dict = ipc_zstd_dict_path();
    my @args = (level => IPC_DEFAULT_ZSTD_LEVEL);
    push @args => (dictionary => $dict) if defined $dict;
    return ['JSON::Zstd', @args];
}

# Default kwargs for ipcm_spawn(): protocol + serializer.
sub ipc_default_spawn_args {
    return (
        protocol   => ipc_default_protocol(),
        serializer => ipc_default_serializer(),
    );
}

# Default kwargs for ipcm_connect() from non-services. The
# ConnectionUnix driver builds a listen socket by default so other
# peers can connect back; collectors and the parent-side spawn
# handle never receive inbound traffic and skip the socket. Services
# (Role::Service consumers) keep listen=1 by default so peers can
# reach them.
sub ipc_default_connect_args {
    return (listen => 0);
}

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

sub start_process {
    my ($cmd, $post_fork) = @_;

    confess "cmd is required and must be an arrayref with content" unless $cmd && @$cmd;
    confess "cmd may not contain undefined values" if grep { !defined($_) } @$cmd;

    my $pid = fork // die "Could not fork: $!";
    return $pid if $pid;

    $post_fork->() if $post_fork;

    { no warnings; exec(@$cmd) }
    print STDERR "Failed to exec " . join(' ', @$cmd) . ": $!\n";
    exit(255);
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
