package Test2::Harness2::Util::File;
use strict;
use warnings;

our $VERSION = '2.000011';

use IO::Handle;

use Test2::Harness2::Util();
use Test2::Harness2::Util qw/tinysleep/;
use Time::HiRes qw/time/;

use Carp qw/croak confess/;
use Fcntl qw/SEEK_SET SEEK_CUR/;

use Object::HashBase qw{
    -name
    -_fh
    -_init_fh
    done
    -line_pos
    <skip_bad_decode
    -_watch_state
    -_inotify
    -_inotify_watch
    -_inotify_broken
};

# Remove this for FileMonitor
# Linux::Inotify2 is the most efficient change-detection primitive on
# Linux. Gated via a constant so the whole codebase has a single
# "is it usable" check; consumers that hit a runtime problem flip
# _inotify_broken on the instance so the object falls back permanently
# to stat-based checks.
use constant HAS_INOTIFY => !!eval { require Linux::Inotify2; 1 };

sub exists { -e $_[0]->{+NAME} }

sub decode { shift; $_[0] }
sub encode { shift; $_[0] }

sub init {
    my $self = shift;

    croak "'name' is a required attribute" unless $self->{+NAME};

    $self->{+_INIT_FH} = delete $self->{fh};
}

sub open_file {
    my $self = shift;
    return Test2::Harness2::Util::open_file($self->{+NAME}, @_);
}

sub maybe_read {
    my $self = shift;
    return undef unless -e $self->{+NAME};
    return $self->read;
}

sub read {
    my $self = shift;
    my $out  = Test2::Harness2::Util::read_file($self->{+NAME});

    my $ok = eval { $out = $self->decode($out); 1 };
    my $err = $@;
    confess "$self->{+NAME}: $err" unless $ok;
    return $out;
}

sub rewrite {
    my $self = shift;
    return Test2::Harness2::Util::write_file($self->{+NAME}, $self->encode(@_));
}

sub write {
    my $self = shift;
    return Test2::Harness2::Util::write_file_atomic($self->{+NAME}, $self->encode(@_));
}

# Remove everything below this for filemonitor related changes
sub reset {
    my $self = shift;
    delete $self->{+_FH};
    delete $self->{+DONE};
    delete $self->{+LINE_POS};
    return;
}

sub fh {
    my $self = shift;
    return $self->{+_FH}->{$$} if $self->{+_FH}->{$$};

    # Remove any other PID handles
    $self->{+_FH} = {};

    if (my $fh = $self->{+_INIT_FH}) {
        $self->{+_FH}->{$$} = $fh;
    }
    else {
        $self->{+_FH}->{$$} = Test2::Harness2::Util::maybe_open_file($self->{+NAME}) or return undef;
    }

    $self->{+_FH}->{$$}->blocking(0);
    return $self->{+_FH}->{$$};
}

sub read_line {
    my $self = shift;
    my %params = @_;

    my $pos = $params{from};
    $pos = $self->{+LINE_POS} ||= 0 unless defined $pos;

    my $fh = $self->{+_FH}->{$$} || $self->fh or return undef;
    seek($fh, $pos, SEEK_SET) or die "Could not seek: $!"
        if eof($fh) || tell($fh) != $pos;

    my $line = <$fh>;

    # No line, nothing to do
    return unless defined $line && length($line);

    # Partial line, hold off unless done
    return unless $self->{+DONE} || substr($line, -1, 1) eq "\n";

    my $new_pos = tell($fh);
    die "Failed to 'tell': $!" if $new_pos == -1;

    my $err = 0;
    unless (eval { $line = $self->decode($line); 1 }) {
        $err = $@ // 'error';
        confess "$self->{+NAME} ($pos -> $new_pos): $err" unless $self->{+SKIP_BAD_DECODE};
        warn "Skipping line that failed to decode: $err\n" if $self->{+SKIP_BAD_DECODE} > 1;
        $line = undef;
    }

    $self->{+LINE_POS} = $new_pos unless defined $params{peek} || defined $params{from};
    return $line unless wantarray;
    return ($pos, $new_pos, $line, $err);
}

# ----------------------------------------------------------------------
# Change detection
#
# Every File object knows how to tell "has my backing path changed
# since we last looked?". The cheap path is a stat-tuple compare:
# device, inode, size and mtime together detect appends, atomic
# rename-into-place rewrites, truncations, and relocations. When
# Linux::Inotify2 is available we also open an inotify watch on the
# path and consume pending events as an early-out signal -- this
# catches rapid back-to-back writes that land inside a single mtime
# tick on filesystems with one-second stamp resolution.
#
# Callers should treat the stat-tuple as the source of truth; the
# inotify short-circuit only reports "change happened" faster.
#
#   $hashref = $file->_current_state
#       { dev, inode, size, mtime } from stat(), or undef if the
#       path does not exist.
#
#   $bool = $file->changed
#       True when the current state differs from the last recorded
#       state (or no state has been recorded yet), or inotify
#       reports pending events. False when everything matches.
#
#   $file->_record_state
#       Stash the current state so the next changed() call has
#       something to compare against. Subclasses call this after
#       a successful read. Uses the most recent reading of the file
#       via _current_state.
#
#   $file->wait_for_change($timeout)
#       Block until changed() becomes true or $timeout seconds
#       elapse. Uses inotify's select-able descriptor when possible;
#       otherwise falls back to a Time::HiRes sleep loop that
#       re-checks changed() between naps. Returns 1 if the file
#       changed, 0 if the timeout fired.
sub _current_state {
    my $self = shift;
    my @st = stat($self->{+NAME});
    return undef unless @st;
    return {
        dev   => $st[0],
        inode => $st[1],
        size  => $st[7],
        mtime => $st[9],
    };
}

sub _record_state {
    my $self = shift;
    my ($state) = @_;
    $state //= $self->_current_state;
    $self->{+_WATCH_STATE} = $state;
    return;
}

sub _inotify_fh {
    my $self = shift;

    return undef unless HAS_INOTIFY;
    return undef if $self->{+_INOTIFY_BROKEN};

    return $self->{+_INOTIFY}->fileno
        if $self->{+_INOTIFY} && $self->{+_INOTIFY_WATCH};

    my $inot;
    my $ok = eval {
        $inot = Linux::Inotify2->new;
        $inot->blocking(0);
        1;
    };
    unless ($ok) {
        $self->{+_INOTIFY_BROKEN} = 1;
        return undef;
    }

    my $path = $self->{+NAME};
    # Inotify on a path requires the path to exist. If it does not
    # yet, fall back silently; the caller's stat-based changed()
    # path still works and we can install the watch later on the
    # first hit.
    return undef unless -e $path;

    my $watch;
    $ok = eval {
        $watch = $inot->watch(
            $path,
            Linux::Inotify2::IN_MODIFY()
                | Linux::Inotify2::IN_CREATE()
                | Linux::Inotify2::IN_MOVED_TO()
                | Linux::Inotify2::IN_DELETE_SELF()
                | Linux::Inotify2::IN_MOVE_SELF()
                | Linux::Inotify2::IN_ATTRIB(),
        );
        1;
    };
    unless ($ok && $watch) {
        $self->{+_INOTIFY_BROKEN} = 1;
        return undef;
    }

    $self->{+_INOTIFY}       = $inot;
    $self->{+_INOTIFY_WATCH} = $watch;
    return $inot->fileno;
}

sub _inotify_has_events {
    my $self = shift;

    my $inot = $self->{+_INOTIFY};
    return 0 unless $inot;

    my @events = $inot->read;
    return scalar(@events) ? 1 : 0;
}

sub changed {
    my $self = shift;

    # Install the inotify watch lazily so callers that never ask
    # about change state do not pay for it.
    $self->_inotify_fh;
    return 1 if $self->_inotify_has_events;

    my $cur   = $self->_current_state;
    my $prior = $self->{+_WATCH_STATE};

    # A missing file is "changed" the first time we notice it going
    # away; once both sides agree the file is gone, further checks
    # return false. Same logic for the first appearance.
    unless (defined $cur) {
        return 0 if !defined $prior;
        return 1;
    }
    return 1 unless defined $prior;

    for my $k (qw/dev inode size mtime/) {
        return 1 if ($cur->{$k} // -1) != ($prior->{$k} // -1);
    }
    return 0;
}

sub wait_for_change {
    my $self = shift;
    my ($timeout) = @_;

    my $deadline = defined $timeout ? time() + $timeout : undef;

    if (my $fh = $self->_inotify_fh) {
        require IO::Select;
        my $sel = IO::Select->new($fh);
        while (1) {
            return 1 if $self->changed;

            my $remaining;
            if (defined $deadline) {
                $remaining = $deadline - time();
                return 0 if $remaining <= 0;
            }
            # can_read returns immediately when events are already
            # queued; the timeout caps the block otherwise. A zero-
            # event wake still drives us back through changed() in
            # case the stat-tuple comparison catches something
            # inotify missed (rare, but robust).
            $sel->can_read($remaining);
        }
    }

    # Fallback: small-sleep poll. Most filesystems report mtime with
    # one-second resolution, so we sleep well below that to avoid
    # missing a rapid-succession rewrite.
    while (1) {
        return 1 if $self->changed;
        if (defined $deadline) {
            my $remaining = $deadline - time();
            return 0 if $remaining <= 0;
        }
        tinysleep(0.05);
    }
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::File - Utility class for manipulating a file.

=head1 DESCRIPTION

Base class for the harness's file helpers. Wraps a path in an object that can
be opened, read in full, written atomically, or iterated line-by-line. The
base class does no encoding; subclasses override C<decode>/C<encode> to layer
a format (see L<Test2::Harness2::Util::File::JSON>,
L<Test2::Harness2::Util::File::JSONL>, L<Test2::Harness2::Util::File::Value>).

=head1 SYNOPSIS

    use Test2::Harness2::Util::File;

    my $f = Test2::Harness2::Util::File->new(name => '/path/to/file');

    $f->write($content);

    my $fh = $f->open_file('<');

    # Read, throw exception if it cannot read
    my $content = $f->read();

    # Try to read, but do not throw an exception if it cannot be read.
    my $content_or_undef = $f->maybe_read();

    my $line1 = $f->read_line();
    my $line2 = $f->read_line();
    ...

=head1 ATTRIBUTES

=over 4

=item $filename = $f->name

The filename. Required at construction.

=item $bool = $f->done

True once C<read_line()> has observed every line of the file. Used in
conjunction with L</SKIP_BAD_DECODE>-style partial-line handling to
distinguish "wait for more data" from "end of file".

=item $int = $f->skip_bad_decode

When truthy, C<read_line()> tolerates decode errors on a line instead of
throwing. At C<2> or above a diagnostic is C<warn>ed for each skipped
line. At C<1> the offending line is silently dropped.

=back

=head1 METHODS

=over 4

=item $decoded = $f->decode($encoded)

Identity transform in the base class; override in subclasses that layer
a format on top of the raw bytes.

=item $encoded = $f->encode($decoded)

Identity transform in the base class; override in subclasses that layer
a format on top of the raw bytes.

=item $bool = $f->exists()

True when the file exists on disk.

=item $content_or_undef = $f->maybe_read()

Return the file's contents (the whole file as a single decoded value) or
C<undef> when the file is missing.

=item $fh = $f->open_file()

=item $fh = $f->open_file($mode)

Open the backing file. Delegates to L<Test2::Harness2::Util/open_file>,
so C<.gz>/C<.bz2> extensions are transparently decompressed on read.

=item $content = $f->read()

Return the whole file as a single decoded value. Dies if the file is
missing or cannot be decoded.

=item $line = $f->read_line()

Iterator method. Each call returns the next line (decoded) or C<undef>
at EOF. Partial lines (no terminating newline) are held back unless
C<< $self->done >> is true, so streamed writers do not produce torn
lines to readers. Call L</reset> to rewind.

=item $f->reset()

Clear the internal iteration cursor so the next C<read_line> starts
over.

=item $f->write($content)

Atomic write: serialises C<$content> via L</encode>, writes it to a
sibling C<.pend> file, and C<rename>s it over the target under a
signal mask. Readers never observe a partial file.

=item $f->rewrite($content)

Non-atomic write: opens the file in C<< '>' >> mode and overwrites it.
Prefer L</write> unless you explicitly need to avoid the rename.

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
