package App::Yath2::Daemon;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Cwd ();
use File::Spec ();
use IO::Handle;

use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

# Shared helpers used by the daemon-mode yath commands
# (start / stop / status / ping / kill / ps / run / spawn / abort /
# watch / reload / resources).
#
# This module is deliberately small. It has two responsibilities:
#
#   1. Write and read the daemon pointer file. 'yath start' and
#      'yath spawn' write the pointer; every attached command reads
#      it to discover where the running daemon lives.
#   2. Build a Test2::Harness2::Spawn handle that connects to an
#      already-running daemon (rather than forking a new one).
#
# The pointer file format is tiny JSON:
#
#   {
#       "pid":       12345,
#       "workdir":   "/tmp/yath2-12345-AbCdEf",
#       "ipcm_info": { ... IPC::Manager connection info ... },
#       "name":      "harness",
#       "started_at": 1700000000.12345
#   }
#
# Discovery order for the attached commands:
#
#   1. --daemon-workdir=PATH on the command line (future hook; the
#      Stage 14 commands that want one accept it via argv parsing).
#   2. $ENV{YATH_DAEMON_WORKDIR} (for test harnesses and CI scripts
#      that set up a run and then invoke multiple attached commands).
#   3. ./.yath-daemon.json in the current working directory.
#   4. Failure: print a clear error; exit 2.

use constant DISCOVERY_FILE_CWD => '.yath-daemon.json';
use constant POINTER_FILE_NAME  => 'daemon.json';

# Write the daemon pointer into two places:
#   $workdir/daemon.json  - canonical, lives for the daemon's lifetime
#   ./.yath-daemon.json   - discovery hint in the directory the user
#                           invoked the command from (optional; skipped
#                           when the cwd isn't writable or the user
#                           opted out via no_cwd_pointer => 1).
sub write_pointer {
    my (%args) = @_;

    my $workdir = $args{workdir} // croak "'workdir' is required";
    my $pid     = $args{pid}     // croak "'pid' is required";
    my $ipcm    = $args{ipcm_info};
    croak "'ipcm_info' is required" unless defined $ipcm;
    my $name          = $args{name} // 'harness';
    my $no_cwd_pointer = $args{no_cwd_pointer} ? 1 : 0;

    my %pointer = (
        pid        => $pid,
        workdir    => $workdir,
        ipcm_info  => $ipcm,
        name       => $name,
        started_at => Time::HiRes::time(),
    );

    my $json = encode_json(\%pointer);

    my $wd_path = File::Spec->catfile($workdir, POINTER_FILE_NAME);
    _atomic_write($wd_path, $json);

    my @written = ($wd_path);

    unless ($no_cwd_pointer) {
        my $cwd_path = File::Spec->catfile(Cwd::getcwd(), DISCOVERY_FILE_CWD);
        my $ok = eval { _atomic_write($cwd_path, $json); 1 };
        push @written => $cwd_path if $ok;
        # If the cwd isn't writable we carry on silently -- the workdir
        # pointer is the canonical path; the cwd one is just convenience.
    }

    return \@written;
}

# Remove both pointer files. Called by the daemon's exit cleanup path
# and by 'yath start'-the-daemon-parent when it observes the harness
# has exited. Missing files are not an error.
sub remove_pointers {
    my (%args) = @_;
    my $workdir = $args{workdir};

    my @removed;
    if (defined $workdir) {
        my $wd_path = File::Spec->catfile($workdir, POINTER_FILE_NAME);
        if (-f $wd_path) {
            unlink $wd_path and push @removed => $wd_path;
        }
    }

    my $cwd_path = File::Spec->catfile(Cwd::getcwd(), DISCOVERY_FILE_CWD);
    if (-f $cwd_path) {
        # Only unlink when it points at the workdir we're removing --
        # otherwise we could clobber a different daemon's pointer
        # dropped here by another 'yath start'.
        my $ok = eval {
            my $data = decode_json(_read_file($cwd_path));
            if (!defined $workdir || ($data->{workdir} // '') eq $workdir) {
                unlink $cwd_path and push @removed => $cwd_path;
            }
            1;
        };
        # Unreadable pointer: leave it alone so the user can investigate.
    }

    return \@removed;
}

# Read a pointer file. Dies with a clear message if the file is
# missing, unreadable, or malformed.
sub read_pointer {
    my ($path) = @_;
    croak "pointer file '$path' does not exist" unless -f $path;
    my $json = _read_file($path);
    my $data = decode_json($json);
    croak "pointer file '$path' missing 'workdir'"
        unless defined $data->{workdir} && length $data->{workdir};
    croak "pointer file '$path' missing 'ipcm_info'"
        unless defined $data->{ipcm_info};
    return $data;
}

# Locate a daemon pointer by the discovery order described above.
# Returns the decoded pointer hashref + the file it was read from.
# Dies with a user-facing error if no pointer can be found; the
# caller should rethrow or print and exit 2.
sub discover_pointer {
    my (%args) = @_;

    # Explicit workdir -> $workdir/daemon.json
    if (defined(my $wd = $args{daemon_workdir} // $ENV{YATH_DAEMON_WORKDIR})) {
        my $path = File::Spec->catfile($wd, POINTER_FILE_NAME);
        croak "no daemon pointer found at '$path' (is the daemon running?)"
            unless -f $path;
        my $data = read_pointer($path);
        return ($data, $path);
    }

    # Fall back to the cwd hint.
    my $cwd_path = File::Spec->catfile(Cwd::getcwd(), DISCOVERY_FILE_CWD);
    if (-f $cwd_path) {
        my $data = read_pointer($cwd_path);
        return ($data, $cwd_path);
    }

    croak "no yath daemon found (looked for YATH_DAEMON_WORKDIR and './" . DISCOVERY_FILE_CWD . "')";
}

# Build a Test2::Harness2::Spawn handle for an already-running daemon.
# Accepts either a pointer hashref (from discover_pointer) or a workdir
# path via daemon_workdir => $path. Returns a Spawn with
# terminate_on_destroy => 0 (we're attaching, not owning; an attached
# command must not tear down the daemon when its Spawn goes out of
# scope).
sub attach {
    my (%args) = @_;

    my $pointer = $args{pointer};
    unless ($pointer) {
        ($pointer) = discover_pointer(%args);
    }

    require Test2::Harness2::Spawn;
    my $spawn = Test2::Harness2::Spawn->new(
        pid                  => $pointer->{pid},
        ipcm_info            => $pointer->{ipcm_info},
        workdir              => $pointer->{workdir},
        name                 => $pointer->{name} // 'harness',
        terminate_on_destroy => 0,
    );

    return $spawn;
}

# --- internals ---------------------------------------------------------

sub _atomic_write {
    my ($path, $content) = @_;
    my $tmp = "$path.tmp.$$";
    open my $fh, '>', $tmp or die "open '$tmp' for write: $!";
    print {$fh} $content or die "write '$tmp': $!";
    close $fh or die "close '$tmp': $!";
    rename $tmp, $path or die "rename '$tmp' -> '$path': $!";
    return;
}

sub _read_file {
    my ($path) = @_;
    open my $fh, '<', $path or die "open '$path' for read: $!";
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

# Deferred until we reach write_pointer; avoids forcing every consumer
# of the module to pull Time::HiRes when they only want attach().
require Time::HiRes;

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Daemon - Daemon-pointer I/O and attach helpers shared by
the Stage 14 daemon-mode commands.

=head1 DESCRIPTION

Commands that manage or attach to a long-running yath daemon use this
module for two things:

=over 4

=item * B<Pointer file I/O>. C<yath start> and C<yath spawn> write a
tiny JSON file (F<daemon.json>) into the daemon's workdir, and
optionally a F<.yath-daemon.json> hint into the cwd from which they
were invoked. Every attached command (C<stop>, C<status>, C<ping>,
C<kill>, C<ps>, C<run>, C<abort>, C<watch>, C<reload>, C<resources>)
reads the pointer to locate the running daemon.

=item * B<Attach helper>. C<attach()> returns a
L<Test2::Harness2::Spawn> handle wired up against the already-running
daemon's IPC bus (with C<terminate_on_destroy> turned off, so the
attached command does not kill the daemon when its handle goes out of
scope).

=back

See L<IPC_AND_LOGGERS> section 11.2 for the architectural contract:
attached commands do not assume a workdir path; they either accept one
via C<--daemon-workdir=PATH>, read it from C<$ENV{YATH_DAEMON_WORKDIR}>,
or fall through to F<./.yath-daemon.json>.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>.

=cut
