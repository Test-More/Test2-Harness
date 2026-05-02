package Test2::Harness2::Util::FileMonitor;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Time::HiRes qw/stat time/;
use Test2::Harness2::Util qw/tinysleep/;

use Object::HashBase qw{
    <file
    <delegate
    <static
    +_state
    +_have_state
    +_static_seen
    +_inotify
    +_inotify_watch
    +_inotify_broken
};

# Linux::Inotify2 is the most efficient change-detection primitive on
# Linux. Gated via a constant so the whole codebase has a single
# "is it usable" check; consumers that hit a runtime problem flip
# _inotify_broken on the instance so the object falls back permanently
# to stat-based polling.
use constant HAS_INOTIFY => !!eval { require Linux::Inotify2; 1 };

sub init {
    my $self = shift;

    # 'file' is required for live mode (the default). 'static' mode
    # bypasses change detection entirely and may be constructed
    # without a file path -- the monitor exists only to deliver the
    # "already changed once" signal to consumers driven by ->watch on
    # an artifact whose backing archive is sealed.
    croak "'file' is a required attribute"
        unless $self->{+STATIC} || defined $self->{+FILE};

    # Initial state: file is "changed" until the first changed() call
    # returns truthy. _have_state stays false until we first record a
    # snapshot to compare against.
    $self->{+_HAVE_STATE}  = 0;
    $self->{+_STATIC_SEEN} = 0;
}

sub changed {
    my $self = shift;
    return $self->_static_check(record => 1) if $self->{+STATIC};
    return $self->_check(record => 1);
}

# Non-consuming peek: report whether the file has changed since the
# last call to changed() / await_change(), without ack'ing the
# pending change. Useful when one consumer wants to ask "is there
# something new" before another consumer (the actual reader)
# commits. Returns the same shape as changed().
sub peek_changed {
    my $self = shift;
    return $self->_static_check(record => 0) if $self->{+STATIC};
    return $self->_check(record => 0);
}

# Static-archive shape: the backing artifact cannot mutate, so we
# fire the change signal exactly once. First call returns the
# delegate (or 1), every subsequent call returns 0. peek (record=0)
# reports the current state without consuming.
sub _static_check {
    my $self = shift;
    my %params = @_;
    return 0 if $self->{+_STATIC_SEEN};
    $self->{+_STATIC_SEEN} = 1 if $params{record};
    return $self->_changed_result;
}

sub _check {
    my $self = shift;
    my %params = @_;
    my $record = $params{record};

    # Drain any queued inotify events first; their presence is an
    # early-out signal even if the stat tuple has not yet ticked.
    # The drain is destructive on the inotify queue regardless of
    # whether we ack the file-state record below; once an inotify
    # event has been observed, that observation is the change.
    my $inotify_event = $self->_inotify_has_events;

    my $cur = $self->_current_state;

    if (!$self->{+_HAVE_STATE}) {
        $self->_record_state($cur) if $record;
        return $self->_changed_result;
    }

    my $prior = $self->{+_STATE};

    # Missing file -> missing file: no change.
    # Missing -> present, or present -> missing: change.
    if (!defined $cur && !defined $prior) {
        return 0 if !$inotify_event;
        $self->_record_state($cur) if $record;
        return $self->_changed_result;
    }

    if (!defined($cur) || !defined($prior)) {
        $self->_record_state($cur) if $record;
        return $self->_changed_result;
    }

    for my $k (qw/dev inode size mtime/) {
        next if ($cur->{$k} // -1) == ($prior->{$k} // -1);
        $self->_record_state($cur) if $record;
        return $self->_changed_result;
    }

    if ($inotify_event) {
        $self->_record_state($cur) if $record;
        return $self->_changed_result;
    }

    return 0;
}

sub await_change {
    my $self = shift;
    my ($timeout) = @_;

    if ($self->{+STATIC}) {
        # Static archives never produce a second change. Either the
        # one-shot signal has not yet been consumed (return it now,
        # without sleeping) or it has (return 0 immediately, no
        # point burning the timeout).
        return $self->_static_check(record => 1);
    }

    my $deadline = defined $timeout ? time() + $timeout : undef;

    if (my $fh = $self->_inotify_fh) {
        require IO::Select;
        my $sel = IO::Select->new($fh);
        while (1) {
            if (my $rv = $self->changed) {
                return $rv;
            }

            my $remaining;
            if (defined $deadline) {
                $remaining = $deadline - time();
                return 0 if $remaining <= 0;
            }
            # can_read returns immediately when events are already
            # queued; the timeout caps the block otherwise. A zero-
            # event wake still drives us back through changed() in
            # case the stat-tuple comparison catches something
            # inotify missed.
            $sel->can_read($remaining);
        }
    }

    # Fallback: small-sleep poll. Most filesystems report mtime with
    # one-second resolution, so we sleep well below that to avoid
    # missing a rapid-succession rewrite. tinysleep so a SIGCHLD /
    # SIGTERM interrupts the loop promptly instead of being swallowed
    # by Time::HiRes::sleep's internal EINTR retry.
    while (1) {
        if (my $rv = $self->changed) {
            return $rv;
        }
        if (defined $deadline) {
            my $remaining = $deadline - time();
            return 0 if $remaining <= 0;
        }
        tinysleep(0.05);
    }
}

sub _changed_result {
    my $self = shift;
    return $self->{+DELEGATE} // 1;
}

sub _current_state {
    my $self = shift;
    my @st = stat($self->{+FILE});
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
    $self->{+_STATE}      = $state;
    $self->{+_HAVE_STATE} = 1;
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

    # Inotify on a path requires the path to exist. If it does not
    # yet, fall back silently; the stat-based changed() path still
    # works and we install the watch on the next call once the file
    # appears.
    my $path = $self->{+FILE};
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

    # Install lazily so callers that never ask about change state do
    # not pay for it.
    $self->_inotify_fh;

    my $inot = $self->{+_INOTIFY} or return 0;
    my @events = $inot->read;
    return scalar(@events) ? 1 : 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::FileMonitor - Watch a file for changes.

=head1 SYNOPSIS

    use Test2::Harness2::Util::FileMonitor;
    use Test2::Harness2::Util::File::JSONL;

    my $delegate = Test2::Harness2::Util::File::JSONL->new(name => $path);
    my $monitor  = Test2::Harness2::Util::FileMonitor->new(
        file     => $path,
        delegate => $delegate,
    );

    # Idiomatic usage: drive the delegate from the monitor's change-loop.
    while (my $delegate = $monitor->changed) {
        push @lines => $delegate->read_lines;
    }

    # Or block until something happens (or a timeout fires):
    if (my $delegate = $monitor->await_change(1.0)) {
        ... handle delegate ...
    }
    else {
        ... timeout ...
    }

=head1 DESCRIPTION

Watches a single file for changes. The class is path-oriented (it holds
the path, not a filehandle) and uses hi-res C<mtime> together with
C<dev>/C<inode>/C<size> to detect appends, atomic rename-into-place
rewrites, truncations, and relocations. Where L<Linux::Inotify2> is
available it is used as an early-out signal in addition to the stat
tuple; callers do not need to opt in.

The monitor carries an optional B<delegate> object. When set, the
truthy return value of L</changed> and L</await_change> is the delegate
itself, so callers can write the idiomatic loop above without holding
a separate variable. Without a delegate the truthy return value is a
plain C<1>.

=head2 Race window

Between the moment L</changed> reports a change and the moment the
delegate reads, a writer may have written nothing new and the delegate
may return zero items. This is intentional and documented; treat the
returned delegate as "the file changed, look at it" rather than "the
file has new content for you right now." Loops that consume zero
items per iteration are safe.

=head1 ATTRIBUTES

=over 4

=item file (required when C<static> is false)

The absolute path to the file being monitored. Required unless
C<static> is true.

=item delegate (optional)

An arbitrary object (commonly a L<Test2::Harness2::Util::File> subclass
or a L<Test2::Harness2::Util::Zstd::Reader>) returned in place of C<1>
on every truthy L</changed> / L</await_change> result.

=item static (optional, default false)

When true, bypass change detection entirely: the first
L</changed> / L</peek_changed> / L</await_change> call returns the
truthy result (the delegate or C<1>) and every subsequent call
returns C<0>. Used when watching an artifact backed by a sealed
archive, where the underlying bytes cannot mutate; consumers can
write the same C<while (my $d = $monitor-E<gt>changed) { ... }> loop
across both live and static backings.

=back

=head1 METHODS

=over 4

=item $delegate_or_bool = $f->changed

Returns C<$delegate> when a delegate was set and the file has changed
since the previous call (or this is the first call), C<1> when no
delegate was set and the file has changed, and C<0> when the file has
not changed. Never blocks. Initial call always reports a change.

=item $delegate_or_bool = $f->peek_changed

Same shape as L</changed>, but does B<not> ack a pending change. Used
when one consumer wants to peek "is there new content?" while
another consumer (the actual reader) handles the commit. Calling
C<peek_changed> repeatedly returns the same truthy value until a
real C<changed> call ack's it.

=item $delegate_or_bool = $f->await_change

=item $delegate_or_bool = $f->await_change($timeout)

Blocks until L</changed> would return truthy, or the optional
C<$timeout> (seconds) elapses. Returns the same shape as L</changed>
on a change; returns C<0> on timeout. The poll loop uses
L<Test2::Harness2::Util/tinysleep> so signals (SIGCHLD / SIGTERM)
interrupt the wait rather than being absorbed by an internal retry.

=item $delegate = $f->delegate

Returns the delegate object passed to the constructor, or C<undef>.

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
