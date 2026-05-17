package App::Yath2::Role::Log;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Role::Tiny;

# The formal contract every yath Log backend consumes. Today
# implemented by App::Yath2::Log::Live, App::Yath2::Log::Directory,
# App::Yath2::Log::TarZIdx, and App::Yath2::Log::DB.
#
# Phase 1 of the DB rebuild (AI_DOCS/2026-05-08-yath-db-rebuild.md §6)
# introduces this role. The required-method list is the union of
# every method any current Log backend exposes publicly plus the
# private _artifact_* family that App::Yath2::Log::Artifact calls
# back into.

requires qw{
    services runs jobs tries last_try
    has_service has_run has_job has_try

    artifacts
    list_files

    event events end_of_events reset

    extract archive

    absolute_path

    _artifact_exists _artifact_read _artifact_iter_records
    _artifact_list_dir _artifact_open_fh _artifact_save
};

# ----- Defaults -----
#
# Acceptable role-level defaults: methods whose body is genuinely
# uniform across every Log consumer. Consumers may still override
# (Live overrides is_live/static, Directory/TarZIdx override
# _decompress_jsonl_bytes for slight performance/dependency reasons,
# Log::DB overrides insert).

# Most Logs are static (sealed); only Live wants is_live=1 / static=0.
sub is_live { 0 }
sub static  { 1 }

# EOE is just "did end_of_events return true?" everywhere. Each
# consumer implements end_of_events; this surfaces it under the
# shorter alias.
sub EOE { $_[0]->end_of_events }

# Pure zstd plumbing: walk a possibly-multi-frame zstd byte string and
# return the concatenated plaintext. Identical across all consumers
# (events.jsonl is multi-frame; whole-file snapshots are single-frame;
# concat-decoding is correct either way). Consumers may override with
# a slightly cheaper implementation when they already loaded the zstd
# dependencies.
sub _decompress_jsonl_bytes {
    my ($self, $bytes) = @_;
    require Test2::Harness2::Util::Zstd;
    require Compress::Zstd;

    my $out    = '';
    my $offset = 0;
    while ($offset < length $bytes) {
        my $size = Test2::Harness2::Util::Zstd::zstd_frame_size(substr($bytes, $offset));
        croak "incomplete zstd frame in jsonl bytes" unless defined $size;
        my $frame = substr($bytes, $offset, $size);
        $offset += $size;
        my $plain = Compress::Zstd::decompress($frame);
        croak "zstd decompress failed in jsonl bytes" unless defined $plain;
        $out .= $plain;
    }
    return $out;
}

# artifact_for_producer($producer, $kind) looks up the artifact ref
# for $kind on the producer descriptor and opens a reader for it.
# Returns undef when no ref of that kind is recorded. Delegates the
# actual open to _open_artifact_for_producer so each backend can
# supply its own low-level read machinery.
sub artifact_for_producer {
    my ($self, $producer, $kind) = @_;
    my $ref = $producer->artifact_ref($kind);
    return undef unless defined $ref;
    return $self->_open_artifact_for_producer($producer, $kind, $ref);
}

# Default: croak. Every backend that carries on-disk or in-memory
# artifacts overrides this with its own open routine.
sub _open_artifact_for_producer {
    my ($self) = @_;
    croak(ref($self) . " does not implement _open_artifact_for_producer yet");
}

# insert($source_log) reverses the data flow: it is the DB-backed
# logs' way of importing another archive. Filesystem-shaped backends
# (Directory / Live / TarZIdx) cannot serve as an insert sink, so the
# default croaks. App::Yath2::Log::DB overrides with a real
# implementation that delegates to its underlying App::Yath2::DB
# backend.
sub insert {
    my $self  = shift;
    my $class = ref($self) || $self;
    croak "insert is only available on DB-backed Logs (this is $class); " . "use \$db->insert(\$source_log) instead";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Role::Log - Contract every yath Log backend consumes.

=head1 DESCRIPTION

A L<Role::Tiny> role enumerating the public Log reader API plus the
private helpers L<App::Yath2::Log::Artifact> calls back into the
owning Log. Every backend that L<App::Yath2::Log> dispatches to
implements this role.

Consumers in this distribution:

=over 4

=item L<App::Yath2::Log::Live>

A still-being-written workdir.

=item L<App::Yath2::Log::Directory>

A sealed (post-extract or otherwise idle) directory tree.

=item L<App::Yath2::Log::TarZIdx>

A tar.zidx archive (USTAR + per-entry zstd + a trailing index).

=item L<App::Yath2::Log::DB>

A thin proxy in front of an L<App::Yath2::DB> instance plus a uuid.

=back

=head1 SYNOPSIS

    package My::Log::Backend;
    use strict;
    use warnings;

    use Role::Tiny::With;
    with 'App::Yath2::Role::Log';

    # ... define every required method below ...

    1;

=head1 REQUIRED METHODS

Each consumer must implement every method listed below. Behavior
notes mirror the contract every backend already satisfies; see the
individual backend modules for backend-specific tradeoffs.

=head2 Listing

=over 4

=item @ords = $log->runs

List the C<run_ord> integers of every run in this archive.

=item @names = $log->services
=item @names = $log->services($run_ord)

List service names. With no argument, returns globally-scoped
services; with a C<$run_ord>, returns services scoped to that run.

=item @ords = $log->jobs($run_ord)

List the C<job_ord> integers for every job under C<$run_ord>.

=item @ords = $log->tries($run_ord, $job_ord)

List the C<try_ord> integers for every attempt at the given job.

=item $ord = $log->last_try($run_ord, $job_ord)

Return the highest C<try_ord> for the given job, or C<undef> when
no tries have been recorded.

=item $bool = $log->has_run($run_ord)
=item $bool = $log->has_job($run_ord, $job_ord)
=item $bool = $log->has_try($run_ord, $job_ord, $try_ord)
=item $bool = $log->has_service($name)
=item $bool = $log->has_service($name, $run_ord)

Existence checks. Return 0 (or false) for missing rows; tolerant of
malformed input (return 0 rather than croak).

=item @paths = $log->list_files

Enumerate every artifact in this archive as an on-disk-relative
path (e.g. C<runs/0/jobs/0/0/events.jsonl.zst>). Drives extract
and archive serialization.

=back

=head2 Artifact factory

=over 4

=item $artifact = $log->artifacts(...)

Construct an L<App::Yath2::Log::Artifact> handle bound to a scope.
Accepted shapes:

    $log->artifacts                          # archive root
    $log->artifacts($service_name)           # global service
    $log->artifacts($run_ord)                # run scope
    $log->artifacts($run_ord, $service)      # run-scoped service
    $log->artifacts($run_ord, $job_ord)      # job at last_try
    $log->artifacts($run_ord, $job_ord, $t)  # specific job try
    $log->artifacts({run_id => $r, ...})     # hashref form

=back

=head2 Event walker

=over 4

=item $event = $log->event
=item $event = $log->event($timeout)

Return the next event from the depth-first walk over collector
trees, or C<undef> when no event is available within C<$timeout>
seconds (or at end-of-stream). Each consumer keeps its own walker
state.

=item @events = $log->events
=item @events = $log->events($timeout)

Drain every currently-available event. Returns the list (which may
be empty); a trailing C<undef> in the list signals end-of-stream.

=item $bool = $log->end_of_events

True when no further events will ever appear.

=item $log->reset

Reset the walker so subsequent C<event> calls restart from the
beginning.

=back

=head2 Conversion / archival

=over 4

=item $log_dir = $log->extract($dir, %opts)

Materialize this archive into a directory tree under C<$dir> and
return an L<App::Yath2::Log::Directory> handle pointing at it.
Options include C<compressed =E<gt> 1> (preserve C<.zst> suffixes)
and C<runs =E<gt> [...]> / C<exclude_runs =E<gt> [...]>.

=item $log->archive($out_path, %opts)

Materialize this archive at C<$out_path> in the requested format
(C<format =E<gt> 'tar.zidx'> by default; C<'sqlite'> for the
DB-backed form).

=back

=head2 Filesystem path

=over 4

=item $abs = $log->absolute_path($rel)

Return the absolute on-disk path for C<$rel> when the backend has
one (Live, Directory). Backends without a per-artifact filesystem
path (TarZIdx, DB) croak.

=back

=head2 Private artifact helpers

These methods are called by L<App::Yath2::Log::Artifact> on its
C<{log}> ref. Consumers must implement them; end users do not call
them directly.

=over 4

=item ($exists, $is_zst) = $log->_artifact_exists($rel)

Probe for an artifact at C<$rel>. Returns a two-element list:
existence flag and whether the on-disk form is C<.zst>-suffixed.

=item $bytes = $log->_artifact_read($rel)

Read the artifact at C<$rel>, returning bytes in whichever shape
matches the requested suffix (plaintext when called without
C<.zst>, compressed when called with).

=item $iter = $log->_artifact_iter_records($base, $stem)

Read a JSONL artifact at C<$base/$stem>. Returns one of:

=over 4

=item *

A L<Test2::Harness2::Util::JSONL::Reader> bound to the artifact's
plaintext bytes (used by the DB backend so callers do not pay the cost
of decoding the entire artifact upfront).

=item *

An arrayref of decoded records (used by backends that already hold
the records in memory, e.g. C<App::Yath2::Log::TarZIdx>).

=item *

C<undef> when the artifact is absent.

=back

Callers consume the result through whichever shape is returned: an
arrayref is iterated directly, a Reader exposes
C<read_lines> / C<readline>.

=item @names = $log->_artifact_list_dir($rel)

List basenames (not full paths) of artifacts at the relative
directory C<$rel>.

=item $fh = $log->_artifact_open_fh($rel)

Open C<$rel> and return a filehandle suitable for streaming reads.

=item $id = $log->_artifact_save(%opts)

Persist a single artifact. Required keys: C<rel> and C<bytes>;
C<compress =E<gt> 1> requests client-side zstd. Returns a backend-
specific identifier string for the persisted artifact.

=back

=head1 PROVIDED METHODS

Defaults installed by this role. Consumers may override for backend-
specific behavior; the Live backend overrides C<is_live> / C<static>,
the DB backend overrides C<insert>, etc.

=over 4

=item $bool = $log->is_live

C<0> by default. Live workdirs override to C<1>.

=item $bool = $log->static

C<1> by default. Live workdirs override to C<0>.

=item $bool = $log->EOE

Alias for C<end_of_events>.

=item $plain = $log->_decompress_jsonl_bytes($bytes)

Multi-frame zstd concat decompress. Pure plumbing; no DB or
filesystem coupling. Consumers may override with a cheaper local
implementation when they already have the zstd dependencies loaded.

=item $reader = $log->artifact_for_producer($producer, $kind)

Look up the artifact ref for C<$kind> on C<$producer> and open a
reader for it. Returns C<undef> when the producer carries no ref of
that kind. Delegates to C<_open_artifact_for_producer> so each
backend can supply its own low-level reader.

=item $log->_open_artifact_for_producer($producer, $kind, $ref)

Backend hook called by C<artifact_for_producer> once the ref has been
resolved. The default implementation croaks; each backend overrides
with logic appropriate to its storage model (e.g. the Directory
backend opens a L<Test2::Harness2::Util::JSONL::Reader> on the
relative on-disk path carried in C<$ref>).

=item $log->insert($source_log, %opts)

Default croaks: insert is meaningful only on DB-backed Logs.
L<App::Yath2::Log::DB> overrides with a real implementation that
delegates to its underlying L<App::Yath2::DB>.

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
