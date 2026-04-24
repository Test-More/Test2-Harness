package App::Yath2::Streamer::Static;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Basename qw/dirname/;
use File::Path qw/make_path/;
use File::Temp qw/tempdir/;

use Test2::Harness2::Util qw/load_module/;

use parent 'App::Yath2::Streamer::Base';
use Object::HashBase qw{
    <log
    +archive
    +archive_tmpdir
    +archive_extracted
};

# Static mode: read a completed log directory (or .yath archive) and
# synthesise lifecycle facets from the final state snapshot(s) each
# run's records_state loggers wrote. Pass general-event loggers
# through unchanged.
#
# Required:
#   log => "/path/to/logs"  (directory) or "/path/to/run.yath" (archive)
sub _bootstrap {
    my $self = shift;

    my $log = $self->{+LOG}
        // croak "'log' is required for " . __PACKAGE__;

    croak "Static streamer requires a directory or log archive; got '$log'"
        unless -d $log || -f $log;

    # Both the directory and archive forms flow through LogArchive --
    # the Directory backend handles bare directories, the Tar / Zip /
    # SevenZip backends handle archives -- so the rest of this class
    # reads artifacts(), runs(), read_file(), etc. uniformly. Require
    # lazily so live-only callers do not drag in the archive backends.
    require App::Yath2::LogArchive;

    my $archive = App::Yath2::LogArchive->new(path => $log);
    $self->{+ARCHIVE}           = $archive;
    $self->{+ARCHIVE_EXTRACTED} = {};

    my @runs = @{$self->{+RUNS} // []};

    # Validate requested runs against the archive's run list.
    my %known = map { $_ => 1 } $archive->runs;
    for my $rid (@runs) {
        croak "unknown run '$rid' in '$log'"
            unless $known{$rid};
    }

    for my $rid (@runs) {
        my $scope_map = $archive->artifacts($rid);
        my $state     = $self->_collect_static_state($scope_map);
        $self->_apply_run_state($rid, $state) if $state;

        $self->_setup_static_event_readers($scope_map);
    }

    return;
}

sub _tick {
    my $self = shift;

    # General-event pass-through. In static mode the archive is
    # complete so the first poll returns every line; subsequent
    # polls return nothing and next() will unblock.
    $self->_drain_event_readers;

    return;
}

# Resolve an artifact's relative path to a local filesystem path.
# Directory input: returns $LOG/$rel directly (no extraction).
# Archive input: extracts the single file into a private tempdir the
# first time it is asked for, caches the resulting path, and returns
# the cached path on subsequent calls.
sub _resolve_path {
    my ($self, $rel) = @_;

    my $archive = $self->{+ARCHIVE};
    if ($archive->isa('App::Yath2::LogArchive::Directory')) {
        my $abs = "$self->{+LOG}/$rel";
        return -e $abs ? $abs : undef;
    }

    return $self->{+ARCHIVE_EXTRACTED}->{$rel}
        if exists $self->{+ARCHIVE_EXTRACTED}->{$rel};

    return undef unless $archive->has_file($rel);

    my $tmpdir = $self->{+ARCHIVE_TMPDIR} //=
        tempdir('yath-streamer-XXXXXX', TMPDIR => 1, CLEANUP => 1);

    my $abs = "$tmpdir/$rel";
    my $dir = dirname($abs);
    make_path($dir) unless -d $dir;

    my $in = $archive->read_file($rel);
    open(my $out, '>', $abs) or croak "Could not open '$abs' for write: $!";
    binmode $in;
    binmode $out;
    my $buf;
    while (my $n = read $in, $buf, 8192) {
        print {$out} $buf;
    }
    close $in;
    close $out or croak "Could not close '$abs': $!";

    return $self->{+ARCHIVE_EXTRACTED}->{$rel} = $abs;
}

# Collect the state snapshot for a run by asking every logger whose
# records_state() is true for its fetch_state. Reconcile across
# loggers: cared-about fields must agree when both loggers set them.
sub _collect_static_state {
    my ($self, $scope_map) = @_;

    my @state_snapshots;
    for my $rel (keys %$scope_map) {
        my $class  = $scope_map->{$rel};
        my $loaded = eval { load_module($class); 1 };
        next unless $loaded;
        next unless $class->can('records_state') && $class->records_state;

        my $path = $self->_resolve_path($rel) or next;

        my $reader = $class->log_reader($path);
        my $state  = $class->fetch_state($reader);
        next unless ref($state) eq 'HASH';

        push @state_snapshots => [$class, $state];
    }

    return undef unless @state_snapshots;

    # Merge: take the first snapshot as the base, then cross-check
    # cared-about keys against each subsequent one. Disagreements on
    # cared-about keys throw.
    my ($base_class, $base) = @{$state_snapshots[0]};
    for my $i (1 .. $#state_snapshots) {
        my ($class, $other) = @{$state_snapshots[$i]};
        _assert_states_agree($base_class, $base, $class, $other);
    }

    return $base;
}

sub _setup_static_event_readers {
    my ($self, $scope_map) = @_;

    for my $rel (keys %$scope_map) {
        my $class  = $scope_map->{$rel};
        my $loaded = eval { load_module($class); 1 };
        next unless $loaded;
        next unless $class->can('records_general_events') && $class->records_general_events;

        my $path = $self->_resolve_path($rel) or next;

        my $reader = $class->log_reader($path);
        push @{$self->{+EVENT_READERS}->{$rel}} => [$class, $reader];
    }

    return;
}

sub _assert_states_agree {
    my ($class_a, $a, $class_b, $b) = @_;

    my @cared = qw/run_id created_at pending running done/;
    for my $k (@cared) {
        next unless exists $a->{$k} && exists $b->{$k};
        _same_scalar_or_list($a->{$k}, $b->{$k})
            or croak "state loggers disagree on '$k' ($class_a vs $class_b)";
    }

    # results: for each job_id present in both, agree on the
    # cared-about per-job keys.
    my $ra   = ref($a->{results}) eq 'HASH' ? $a->{results} : {};
    my $rb   = ref($b->{results}) eq 'HASH' ? $b->{results} : {};
    my @jids = do { my %s; $s{$_}++ for keys %$ra, keys %$rb; keys %s };

    for my $jid (@jids) {
        my $ja = $ra->{$jid} or next;
        my $jb = $rb->{$jid} or next;
        for my $k (qw/queued_at started_at completed_at pass exit rel_file abs_file file/) {
            next unless defined $ja->{$k} && defined $jb->{$k};
            _same_scalar_or_list($ja->{$k}, $jb->{$k})
                or croak "state loggers disagree on results.$jid.$k ($class_a vs $class_b)";
        }
    }

    return 1;
}

sub _same_scalar_or_list {
    my ($a, $b) = @_;

    my $ra = ref $a;
    my $rb = ref $b;
    return 0 unless $ra eq $rb;

    if ($ra eq 'ARRAY') {
        return 0 unless @$a == @$b;
        for my $i (0 .. $#$a) {
            return 0 unless _same_scalar_or_list($a->[$i], $b->[$i]);
        }
        return 1;
    }

    if ($ra eq 'HASH') {
        return 0 unless keys(%$a) == keys(%$b);
        for my $k (keys %$a) {
            return 0 unless exists $b->{$k};
            return 0 unless _same_scalar_or_list($a->{$k}, $b->{$k});
        }
        return 1;
    }

    # Plain scalars.
    return 1 if !defined $a && !defined $b;
    return 0 if !defined $a || !defined $b;
    return $a eq $b ? 1 : 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Streamer::Static - Static streamer: replay a completed log archive.

=head1 SYNOPSIS

    use App::Yath2::Streamer::Static;

    # Directory form
    my $s = App::Yath2::Streamer::Static->new(
        log  => "$workdir/logs",
        runs => [$run_id1, $run_id2],
    );

    # Archive file form (.yath)
    my $s = App::Yath2::Streamer::Static->new(
        log => '/path/to/20260424-035943.yath',
        run => $run_id,
    );

    while (my $event = $s->next) { ... }

=head1 DESCRIPTION

Replays events from a completed log directory or C<.yath> archive
via L<App::Yath2::LogArchive>. Synthesises lifecycle facets from
the final state snapshot each C<records_state> logger recorded,
and passes events from C<records_general_events> loggers through
unchanged.

Archives are read lazily: a file is extracted to a private tempdir
only when the streamer actually reads it. Files the streamer never
needs (e.g. the harness JSONL when only the state artifact was
requested) stay inside the archive.

See L<App::Yath2::Streamer::Base> for the public API and
L<App::Yath2::Streamer::Live> for the live-harness counterpart.

=head1 CONSTRUCTOR

=over 4

=item log (required)

Either a directory path (e.g. C<$workdir/logs>) or a C<.yath>
archive file. The directory form is consumed via
L<App::Yath2::LogArchive::Directory>, the archive form picks the
right backend based on the file signature.

=item global / run / runs

Subscription scope. See L<App::Yath2::Streamer::Base>.

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
