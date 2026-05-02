package App::Yath2::LogArchive::Artifact;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Basename qw/dirname/;
use File::Path qw/make_path/;
use File::Spec ();
use File::Temp qw/tempdir/;
use Scalar::Util qw/blessed/;

use Test2::Harness2::Util qw/load_module/;

use Object::HashBase qw{
    <archive
    <relpath
    <logical_name
    <logger_class
    <update_type
    +reader
    +data_cache
    +has_data_cache
    +materialised_path
    +materialised_root
};

# An Artifact handle is the user-facing wrapper around a single
# logical artifact in a log archive. One logger, one or more physical
# files. The handle:
#
#   - Routes single-object reads through ->data (update_type='replace')
#     and multi-object reads through ->next (update_type='append').
#
#   - Provides ->watch which returns a fresh
#     Test2::Harness2::Util::FileMonitor with this Artifact as the
#     monitor's delegate. The FileMonitor's 'static' flag is taken
#     from the archive backend: live Directory archives drive a real
#     change-detection loop; sealed archives short-circuit to "first
#     check truthy, every later check zero".
#
#   - Does NOT cache the FileMonitor internally. ->watch is cheap to
#     call repeatedly; consumers that want one watcher should hold
#     onto its result.
#
# Construction is normally driven by App::Yath2::LogArchive->artifact.
#
# Required attributes:
#
#   archive       The owning LogArchive backend.
#   relpath       Physical relative path inside the archive (e.g.
#                 'runs/<run>/events.jsonl').
#   logger_class  The logger class that produced this artifact (used
#                 to construct the right Reader).
#   update_type   'append' or 'replace'.
#
# Optional:
#
#   logical_name  The artifact's logical name. Cosmetic; useful for
#                 diagnostics.

sub init {
    my $self = shift;

    croak "'archive' is a required attribute"
        unless defined $self->{+ARCHIVE};
    croak "'relpath' is a required attribute"
        unless defined $self->{+RELPATH} && length $self->{+RELPATH};
    croak "'logger_class' is a required attribute"
        unless defined $self->{+LOGGER_CLASS} && length $self->{+LOGGER_CLASS};
    croak "'update_type' is a required attribute"
        unless defined $self->{+UPDATE_TYPE};

    croak "Invalid update_type '$self->{+UPDATE_TYPE}' (expected 'append' or 'replace')"
        unless $self->{+UPDATE_TYPE} eq 'append'
        || $self->{+UPDATE_TYPE} eq 'replace';

    $self->{+HAS_DATA_CACHE} = 0;
}

# {{{ Read API

# Single-object (replace) artifacts: ->data returns the full content
# of the artifact, decoded once via the logger's reader. Subsequent
# calls re-read on a live backend (the file may have been atomically
# replaced); on a static backend the bytes cannot change but we still
# defer caching to the underlying reader.
sub data {
    my $self = shift;
    croak "->data is only valid on update_type='replace' artifacts"
        unless $self->{+UPDATE_TYPE} eq 'replace';

    my $reader = $self->_reader or return undef;
    return undef unless $reader->exists;
    return $reader->maybe_read;
}

# Multi-object (append) artifacts: ->next returns the next pending
# event. Returns undef when nothing new is available (non-blocking).
# On a live backend each call drains whatever the underlying Reader
# has buffered since the previous call. On a static backend the file
# is read once end-to-end and items are returned one at a time until
# the queue empties.
sub next {
    my $self = shift;
    croak "->next is only valid on update_type='append' artifacts"
        unless $self->{+UPDATE_TYPE} eq 'append';

    my $queue = $self->{+DATA_CACHE};
    return shift @$queue if ref($queue) eq 'ARRAY' && @$queue;

    my $reader = $self->_reader or return undef;
    return undef unless $reader->exists;

    if ($self->_archive_is_static) {
        return undef if $self->{+HAS_DATA_CACHE};
        $self->{+HAS_DATA_CACHE} = 1;
    }

    my @items = $reader->read_lines;
    return undef unless @items;
    $self->{+DATA_CACHE} = [@items];
    return shift @{$self->{+DATA_CACHE}};
}

# }}}

# {{{ Watch

# Construct a fresh Test2::Harness2::Util::FileMonitor watching the
# physical file backing this artifact, with the artifact itself as
# the monitor's delegate. The monitor's 'static' flag mirrors the
# archive's: a sealed archive (TarZIdx, or a Directory with live=0)
# yields a static monitor that fires the change signal exactly once;
# a live Directory drives a real stat / inotify loop.
#
# Not cached. Repeated calls produce independent FileMonitor
# instances; consumers that want one monitor should hold onto its
# result.
sub watch {
    my $self = shift;

    require Test2::Harness2::Util::FileMonitor;

    my $static = $self->_archive_is_static ? 1 : 0;
    my $abs    = $self->_resolved_path;

    return Test2::Harness2::Util::FileMonitor->new(
        ($abs ? (file => $abs) : ()),
        delegate => $self,
        static   => $static,
    );
}

# }}}

# {{{ Internal: reader / path resolution

sub _archive_is_static {
    my $self = shift;
    my $arc  = $self->{+ARCHIVE};
    return 0 unless blessed($arc);
    return $arc->static ? 1 : 0
        if $arc->can('static');
    return $arc->can('is_live') && $arc->is_live ? 0 : 1;
}

# Resolve a filesystem path the underlying logger's Reader can open.
# For Directory backends (live or extracted) this is the absolute
# path of the relpath. For TarZIdx (no absolute path), we extract
# the bytes to a private tempdir on first access so the standard
# Reader implementations can stat / open it like any other file.
sub _resolved_path {
    my $self = shift;
    return $self->{+MATERIALISED_PATH} if defined $self->{+MATERIALISED_PATH};

    my $arc = $self->{+ARCHIVE};
    if ($arc->can('absolute_path')) {
        my $abs = eval { $arc->absolute_path($self->{+RELPATH}) };
        return $self->{+MATERIALISED_PATH} = $abs if defined $abs;
    }

    return undef unless $arc->can('read_file') && $arc->can('has_file');
    return undef unless $arc->has_file($self->{+RELPATH});

    my $root = $self->{+MATERIALISED_ROOT}
        //= tempdir('yath-artifact-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $abs = File::Spec->catfile($root, $self->{+RELPATH});
    my $par = dirname($abs);
    make_path($par) unless -d $par;

    my $in = $arc->read_file($self->{+RELPATH});
    open(my $out, '>', $abs) or croak "open $abs: $!";
    binmode $in;
    binmode $out;
    my $buf;
    while (my $n = read $in, $buf, 8192) {
        print {$out} $buf;
    }
    close $in;
    close $out or croak "close $abs: $!";

    return $self->{+MATERIALISED_PATH} = $abs;
}

sub _reader {
    my $self = shift;
    return $self->{+READER} //= do {
        my $abs = $self->_resolved_path or last;
        $self->_build_reader($abs);
    };
}

sub _build_reader {
    my ($self, $abs) = @_;

    my $loaded = eval { load_module($self->{+LOGGER_CLASS}); 1 };
    return undef unless $loaded;

    my $r = $self->{+LOGGER_CLASS}->log_reader($abs);
    return undef unless $r;
    return $r->can('delegate') ? $r->delegate : $r;
}

# }}}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::LogArchive::Artifact - Handle into one logical artifact in a log archive.

=head1 DESCRIPTION

Returned by L<App::Yath2::LogArchive/artifact>. Wraps one logger's
output (one logical artifact -- typically backed by one physical
file). Provides three methods:

=over 4

=item L</data>

The full decoded content of a C<update_type='replace'> artifact.

=item L</next>

The next item from a C<update_type='append'> artifact (non-blocking).

=item L</watch>

A fresh L<Test2::Harness2::Util::FileMonitor> wrapping the artifact
so consumers can write the idiomatic
C<while (my $del = $monitor-E<gt>changed) { ... }> loop. The monitor's
C<static> flag mirrors the archive backend: live Directory archives
drive real change detection; sealed archives (TarZIdx, extracted
directories) fire a one-shot change signal.

=back

The Artifact does not consume a change-watching role itself, and it
does not cache a FileMonitor internally; L</watch> may be called
repeatedly.

=head1 SYNOPSIS

    my $artifact = $la->artifact('runs/RUN/events');           # extension-inferred
    my $artifact = $la->artifact('runs/RUN/events',
                                 prefer => ['jsonl', 'csv']);

    # Single-object (update_type='replace'):
    my $data = $artifact->data;

    # Multi-object (update_type='append'):
    my $w = $artifact->watch;
    while (my $del = $w->changed) {
        while (defined(my $item = $del->next)) {
            ...
        }
    }

=head1 ATTRIBUTES

=over 4

=item archive (required)

The owning LogArchive backend.

=item relpath (required)

Relative path inside the archive of the physical file backing this
artifact.

=item logger_class (required)

Class name of the logger that produced this artifact. Used to
construct an appropriate reader.

=item update_type (required)

C<'append'> or C<'replace'>.

=item logical_name (optional)

The artifact's logical name (the key the artifacts() API used).
Cosmetic.

=back

=head1 METHODS

=over 4

=item $bytes_or_struct = $artifact->data

Single-object artifacts only. Returns the full decoded content of
the artifact (typically a hashref for a JSON file).

=item $item = $artifact->next

Multi-object artifacts only. Returns the next pending item, or
undef when nothing new is available. Non-blocking.

=item $monitor = $artifact->watch

Returns a fresh L<Test2::Harness2::Util::FileMonitor> with this
Artifact as the monitor's delegate. Not cached; repeated calls
produce independent monitors.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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
