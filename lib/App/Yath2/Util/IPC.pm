package App::Yath2::Util::IPC;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use POSIX qw/strftime/;

use App::Yath2();
use File::Spec();
use IPC::Manager::Serializer::JSON();
use Sys::Hostname qw/hostname/;
use Test2::Harness2::Util qw/write_file_atomic_mode/;
use Test2::Harness2::Util::IPC qw/pid_is_running/;

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    resolve_ipc_filename
    resolve_ipc_dir
    write_ipc_file read_ipc_file unlink_ipc_file
    find_ipc_files
    publish_ipc_file
};

# IPC info filename:
#   ${project}-${user}-${command}-${stamp}-yath-${pid}-ipc.json
#
# Sortable by stamp; pid disambiguates concurrent same-command runs
# in the same project; the trailing -yath-${pid}-ipc.json segment is
# the regex anchor used by find_ipc_files when scanning a directory.
sub resolve_ipc_filename {
    my %p = @_;

    my $project = $p{project} // croak "'project' is required";
    my $user    = $p{user}    // croak "'user' is required";
    my $command = $p{command} // croak "'command' is required";
    my $stamp   = $p{stamp}   // croak "'stamp' is required";
    my $pid     = $p{pid}     // croak "'pid' is required";

    return "${project}-${user}-${command}-${stamp}-yath-${pid}-ipc.json";
}

sub _writable_dir {
    my ($d) = @_;
    return undef unless defined $d && length $d;
    return undef unless -d $d      && -w _;
    return $d;
}

sub _dir_for_symbol {
    my ($sym, $settings) = @_;

    return $settings->yath->cwd if $sym eq 'cwd';
    return File::Spec->tmpdir() if $sym eq 'tempdir';

    if ($sym eq 'user_rc') {
        my $f = $settings->yath->user_config_file or return undef;
        my ($vol, $dirs) = File::Spec->splitpath($f);
        return File::Spec->catdir(File::Spec->splitdir($dirs));
    }

    if ($sym eq 'project_rc') {
        my $f = $settings->yath->config_file or return undef;
        my ($vol, $dirs) = File::Spec->splitpath($f);
        return File::Spec->catdir(File::Spec->splitdir($dirs));
    }

    # Raw path. Caller's responsibility to make sense of it.
    return $sym;
}

sub resolve_ipc_dir {
    my ($settings) = @_;

    my $ipc = $settings->ipc;

    if (my $d = _writable_dir($ipc->dir)) {
        return ($d, 0);
    }

    my $order = $ipc->dir_order || [];
    for my $sym (@$order) {
        my $d = _dir_for_symbol($sym, $settings);
        next unless defined $d;
        next unless _writable_dir($d);
        return ($d, ($sym eq 'tempdir' ? 1 : 0));
    }

    croak "no writable IPC directory found in resolution chain";
}

sub write_ipc_file {
    my ($path, $data) = @_;
    croak "'path' required" unless defined $path && length $path;
    croak "'data' required" unless ref $data eq 'HASH';

    my $json = IPC::Manager::Serializer::JSON->serialize($data);

    # 0600: only the user who ran yath may read or write the file. The
    # ipcm_info string inside is sufficient to dial the harness's IPC
    # bus, so non-owner read access is a credential leak.
    write_file_atomic_mode($path, 0600, $json);

    return $path;
}

# publish_ipc_file is the producer-side entry point: a yath command
# that has just spawned a harness service hands settings + spawn +
# workdir + command, and the helper resolves where to write the IPC
# info file, builds the JSON payload, and writes it atomically with
# owner-only perms. Returns the on-disk path so the caller can
# register a cleanup guard against it.
sub publish_ipc_file {
    my %p = @_;

    my $command  = $p{command}  // croak "'command' is required";
    my $settings = $p{settings} // croak "'settings' is required";
    my $spawn    = $p{spawn}    // croak "'spawn' is required";
    my $workdir  = $p{workdir}  // croak "'workdir' is required";

    my $host    = hostname();
    my $user    = $settings->yath->user // $ENV{USER} // (getpwuid($<))[0] // 'unknown';
    my $project = $settings->yath->project // '__UNKNOWN__';
    my $uuid    = $settings->yath->instance_uuid;
    my $stamp   = strftime('%Y%m%d-%H%M%S', localtime);

    my $path;
    if (my $explicit = $settings->ipc->file) {
        $path = $explicit;
    }
    else {
        my ($dir) = resolve_ipc_dir($settings);
        my $name  = resolve_ipc_filename(
            project => $project,
            user    => $user,
            command => $command,
            stamp   => $stamp,
            pid     => $spawn->pid,
        );
        $path = File::Spec->catfile($dir, $name);
    }

    write_ipc_file(
        $path,
        {
            yath_version => $App::Yath2::VERSION,
            command      => $command,
            hostname     => $host,
            user         => $user,
            project      => $project,
            stamp        => $stamp,
            # pid: harness service pid (not $$ writer); used by
            # find_ipc_files for liveness checks.
            pid          => $spawn->pid,
            uuid         => $uuid,
            created_at   => time(),
            workdir      => $workdir,
            ipcm_info    => $spawn->ipcm_info,
        },
    );

    return $path;
}

sub read_ipc_file {
    my ($path) = @_;
    croak "'path' required" unless defined $path && length $path;

    open(my $fh, '<', $path) or croak "open '$path' for read: $!";
    local $/;
    my $body = <$fh>;
    close $fh or croak "close '$path': $!";

    return IPC::Manager::Serializer::JSON->deserialize($body);
}

sub unlink_ipc_file {
    my ($path, $expect_pid) = @_;
    return unless defined $path && length $path;
    return unless -e $path;

    if (@_ >= 2 && defined $expect_pid && $$ != $expect_pid) {
        # Different process (most likely a forked child) is trying to
        # clean up a file the parent registered. Skip.
        return;
    }

    unlink $path or warn "unlink '$path': $!";
    return;
}

my $FILENAME_RX = qr{
    \A
    (?<project>[^/]+?)
    -(?<user>[^-]+?)
    -(?<command>[^-]+?)
    -(?<stamp>\d{8}-\d{6})
    -yath
    -(?<pid>\d+)
    -ipc\.json
    \z
}x;

sub _scan_dir {
    my ($dir) = @_;
    return () unless -d $dir;
    opendir(my $dh, $dir) or return ();
    my @hits;
    while (defined(my $entry = readdir($dh))) {
        next unless $entry =~ $FILENAME_RX;
        push @hits => File::Spec->catfile($dir, $entry);
    }
    closedir $dh;
    return @hits;
}

sub find_ipc_files {
    my %p = @_;

    my $dirs = $p{dirs}
        or croak "'dirs' is required (caller should pass resolve_ipc_dir result or override)";

    my $self_host = hostname();

    # may be undef on purpose -> no host filter
    my $want_host = exists $p{host} ? $p{host} : $self_host;

    # Filter by command name (e.g. 'test', 'start'). Pass either a
    # scalar or arrayref. undef = no command filter.
    my $want_cmds = $p{command}
        ? {map { ($_ => 1) } (ref($p{command}) ? @{$p{command}} : $p{command})}
        : undef;

    my $live = exists $p{live} ? $p{live} : 1;

    my @records;
    for my $dir (@$dirs) {
        for my $path (_scan_dir($dir)) {
            my $rec;
            my $ok  = eval { $rec = read_ipc_file($path); 1 };
            my $err = $@;
            unless ($ok) {
                # Unreadable / corrupt entry. Leave it on disk for an
                # operator to investigate; we do not unlink here, only
                # liveness cleanup is automatic. Warn so the anomaly is
                # not invisible.
                warn "skipping unreadable IPC info file '$path': $err";
                next;
            }

            $rec->{_path} = $path;
            $rec->{hostname} //= '';

            next if $want_cmds && !$want_cmds->{$rec->{command} // ''};
            next if defined($want_host) && $rec->{hostname} ne $want_host;

            if ($live && $rec->{hostname} eq $self_host) {
                unless (pid_is_running($rec->{pid})) {
                    unlink_ipc_file($path);    # no pid arg = unconditional
                    next;
                }
            }

            push @records => $rec;
        }
    }

    @records = sort { ($b->{created_at} // 0) <=> ($a->{created_at} // 0) } @records;
    return \@records;
}

1;

__END__

=pod

=head1 NAME

App::Yath2::Util::IPC - IPC info file helpers

=head1 DESCRIPTION

Helpers for writing, reading, and discovering yath IPC info files.

See C<docs/superpowers/specs/2026-04-25-ipc-info-file-design.md>.

=cut
