package App::Yath2::Log::DB;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Object::HashBase qw{
    <db
    <uuid
};

# `with` is safe at the top because every method here is a regular
# `sub name { ... }` declaration -- those BEGIN-elevate, so they exist
# at compile time when the role's `requires` check runs. (The late-with
# workaround is only needed for `*name = sub { ... }` assignments,
# which never BEGIN-elevate.)
use Role::Tiny::With;
with 'App::Yath2::Role::Log';

# Thin wrapper around an App::Yath2::DB instance plus an archive UUID.
# Every Role::Log method is a one-liner delegating to $self->db with
# our cached uuid prepended.

sub init {
    my $self = shift;

    croak "'db' is required (must be an App::Yath2::DB instance)"
        unless defined $self->{+DB};
    croak "'db' must be an App::Yath2::DB instance"
        unless eval { $self->{+DB}->isa('App::Yath2::DB') };

    croak "'uuid' is required for an archive-scoped Log::DB"
        unless defined $self->{+UUID};

    return;
}

# Read methods: delegate to App::Yath2::DB with our cached uuid.

sub services    { my $s = shift; $s->{+DB}->services($s->{+UUID}, @_) }
sub runs        { my $s = shift; $s->{+DB}->runs($s->{+UUID}, @_) }
sub jobs        { my $s = shift; $s->{+DB}->jobs($s->{+UUID}, @_) }
sub tries       { my $s = shift; $s->{+DB}->tries($s->{+UUID}, @_) }
sub last_try    { my $s = shift; $s->{+DB}->last_try($s->{+UUID}, @_) }
sub has_service { my $s = shift; $s->{+DB}->has_service($s->{+UUID}, @_) }
sub has_run     { my $s = shift; $s->{+DB}->has_run($s->{+UUID}, @_) }
sub has_job     { my $s = shift; $s->{+DB}->has_job($s->{+UUID}, @_) }
sub has_try     { my $s = shift; $s->{+DB}->has_try($s->{+UUID}, @_) }
sub list_files  { my $s = shift; $s->{+DB}->list_files($s->{+UUID}, @_) }

sub absolute_path { my $s = shift; $s->{+DB}->absolute_path(@_) }

sub _artifact_exists       { my $s = shift; $s->{+DB}->artifact_exists($s->{+UUID}, @_) }
sub _artifact_read         { my $s = shift; $s->{+DB}->artifact_read($s->{+UUID}, @_) }
sub _artifact_iter_records { my $s = shift; $s->{+DB}->artifact_iter_records($s->{+UUID}, @_) }
sub _artifact_list_dir     { my $s = shift; $s->{+DB}->artifact_list_dir($s->{+UUID}, @_) }
sub _artifact_open_fh      { my $s = shift; $s->{+DB}->artifact_open_fh($s->{+UUID}, @_) }

# Walker: App::Yath2::DB::Iterator owns the depth-first event walker
# now. Each Log::DB instance lazily builds (and caches) one iterator
# bound to (db, uuid); ->reset rewinds the cached iterator instead of
# allocating a new one so callers see consistent walker state.
sub event         { my $s = shift; $s->_iter->next }
sub events        { my $s = shift; $s->_iter->all }
sub end_of_events { my $s = shift; $s->_iter->EOE }
sub EOE           { my $s = shift; $s->_iter->EOE }
sub reset         { my $s = shift; $s->_iter->reset }

sub _iter {
    my $self = shift;
    return $self->{_iter} //= $self->{+DB}->iterator($self->{+UUID});
}

# Write paths flow through App::Yath2::DB directly.
#
# extract: $log->extract($dir, %opts) -> App::Yath2::Log::Directory
# archive: $log->archive($out, %opts) -> sealed-form Log handle
# insert:  $log->insert($source, %opts) -> $new_archive_id (integer)
sub extract        { my $s = shift; $s->{+DB}->extract($s->{+UUID}, @_) }
sub archive        { my $s = shift; $s->{+DB}->archive_to($s->{+UUID}, @_) }
sub insert         { my $s = shift; $s->{+DB}->insert(@_) }
sub _artifact_save { my $s = shift; $s->{+DB}->save_artifact($s->{+UUID}, @_) }

# Artifact factory: delegated to App::Yath2::DB. The Artifact handle
# returned binds to a uuid-scoped DB clone, so its private _artifact_*
# calls land on App::Yath2::DB without going through this Log::DB at
# all -- meaning bytes are returned in the canonical shapes the data
# layer produces.
sub artifacts { my $s = shift; $s->{+DB}->artifacts($s->{+UUID}, @_) }

# {{{ Producer iterators

# DB-backed logs are always post-mortem (sealed-only in v1). Every
# producer iterator issues exactly one bulk query per producer kind and
# iterates the in-memory result, avoiding N+1 round-trips.
#
# Artifact refs are keyed by artifact_kind. The ref value is the
# artifact_id (DB integer PK), not a filesystem path. A single bulk
# artifact query covers all artifacts for the archive; we index by
# scope (run_id, service_id, job_try_id) and kind, then hand each
# producer its slice.

sub _db_archive_id {
    my $self = shift;
    return $self->{_db_archive_id} //= do {
        $self->{+DB}->_resolve_archive_id($self->{+UUID});
    };
}

# Build a scope->kind->artifact_id index from a single bulk fetch.
# Returns a nested hashref:
#   run      => { $run_id      => { $kind => $artifact_id, ... }, ... }
#   service  => { $service_id  => { $kind => $artifact_id, ... }, ... }
#   job_try  => { $job_try_id  => { $kind => $artifact_id, ... }, ... }
sub _artifact_ref_index {
    my $self = shift;
    return $self->{_artifact_ref_index} //= do {
        my $aid  = $self->_db_archive_id;
        my $rows = $self->{+DB}->{App::Yath2::DB::BACKEND()}->artifact_rows_for_archive($aid);
        my %idx  = (run => {}, service => {}, job_try => {});
        for my $row (@$rows) {
            my $kind = $row->{artifact_kind};
            if (defined $row->{run_id} && !defined $row->{service_id} && !defined $row->{job_try_id}) {
                $idx{run}{$row->{run_id}}{$kind} = $row->{artifact_id};
            }
            elsif (defined $row->{service_id}) {
                $idx{service}{$row->{service_id}}{$kind} = $row->{artifact_id};
            }
            elsif (defined $row->{job_try_id}) {
                $idx{job_try}{$row->{job_try_id}}{$kind} = $row->{artifact_id};
            }
        }
        \%idx;
    };
}

sub run_producers {
    my $self = shift;

    require App::Yath2::Log::Iterator::Producers;
    require App::Yath2::Log::Producer::Run;

    my $rows = $self->{+DB}->run_full_rows($self->{+UUID});
    my $idx  = $self->_artifact_ref_index;
    my $i    = 0;

    return App::Yath2::Log::Iterator::Producers->new(
        next_cb => sub {
            return undef if $i >= @$rows;
            my $r = $rows->[$i++];
            return App::Yath2::Log::Producer::Run->new(
                id            => $r->{run_ord},
                kind          => 'run',
                parent_id     => undef,
                run_id        => $r->{run_ord},
                state         => 'sealed',
                started_at    => $r->{started_at},
                ended_at      => $r->{ended_at},
                pass          => $r->{pass},
                exit          => $r->{run_exit},
                log           => $self,
                artifact_refs => $idx->{run}{$r->{run_id}} // {},
            );
        },
    );
}

sub job_producers {
    my ($self, $run_ord) = @_;
    croak "run_id is required" unless defined $run_ord;

    require App::Yath2::Log::Iterator::Producers;
    require App::Yath2::Log::Producer::Job;

    # One query for all jobs in this run.
    my $aid = $self->_db_archive_id;
    my $b   = $self->{+DB}->{App::Yath2::DB::BACKEND()};
    croak "no such run: $run_ord"
        unless $b->run_exists($aid, $run_ord);
    my $rid  = $b->run_id_for_ord($aid, $run_ord);
    my $jobs = $b->job_rows($aid, $rid);

    # One query for all job_tries in this run (bulk JOIN).
    my $tries   = $b->try_rows_for_run($rid);
    my $art_idx = $self->_artifact_ref_index;

    # Index tries by job_id for O(1) lookup per job.
    my %tries_by_job;
    for my $t (@$tries) {
        push @{$tries_by_job{$t->{job_id}}}, $t;
    }

    # Flatten to (job, try) pairs in job_ord / try_ord order.
    my @pairs;
    for my $j (@$jobs) {
        my @job_tries = sort { $a->{try_ord} <=> $b->{try_ord} } @{$tries_by_job{$j->{job_id}} // []};
        # If a job has no tries yet (shouldn't happen in a sealed DB,
        # but handle gracefully), emit a placeholder with try=0.
        unless (@job_tries) {
            push @pairs, [$j, undef];
            next;
        }
        for my $t (@job_tries) {
            push @pairs, [$j, $t];
        }
    }

    my $i = 0;
    return App::Yath2::Log::Iterator::Producers->new(
        next_cb => sub {
            return undef if $i >= @pairs;
            my ($j, $t) = @{$pairs[$i++]};
            my $try_ord = defined $t ? $t->{try_ord}    : 0;
            my $pass    = defined $t ? $t->{pass}       : undef;
            my $started = defined $t ? $t->{started_at} : undef;
            my $ended   = defined $t ? $t->{ended_at}   : undef;
            my $refs =
                defined $t
                ? ($art_idx->{job_try}{$t->{job_try_id}} // {})
                : {};
            # spec and report are reconstructed from typed columns in the
            # DB layer (never stored as artifact rows). report_available is
            # true whenever a report was ingested, i.e. ended_at is set.
            my $report_avail = (defined $ended || defined $pass) ? 1 : 0;
            return App::Yath2::Log::Producer::Job->new(
                id               => $j->{job_ord},
                kind             => 'job',
                parent_id        => $run_ord,
                run_id           => $run_ord,
                try              => $try_ord,
                state            => 'sealed',
                started_at       => $started,
                ended_at         => $ended,
                pass             => $pass,
                report_available => $report_avail,
                log              => $self,
                artifact_refs    => $refs,
            );
        },
    );
}

sub service_producers {
    my ($self, $run_ord) = @_;

    require App::Yath2::Log::Iterator::Producers;
    require App::Yath2::Log::Producer::Service;

    my $aid = $self->_db_archive_id;
    my $b   = $self->{+DB}->{App::Yath2::DB::BACKEND()};

    my $rows;
    my $rid;
    if (defined $run_ord) {
        croak "no such run: $run_ord"
            unless $b->run_exists($aid, $run_ord);
        $rid  = $b->run_id_for_ord($aid, $run_ord);
        $rows = $b->service_rows($aid, run_id => $rid);
    }
    else {
        $rows = $b->service_rows($aid, run_id => undef);
    }

    my $art_idx = $self->_artifact_ref_index;
    my $i       = 0;

    return App::Yath2::Log::Iterator::Producers->new(
        next_cb => sub {
            return undef if $i >= @$rows;
            my $r = $rows->[$i++];
            return App::Yath2::Log::Producer::Service->new(
                id            => $r->{name},
                kind          => 'service',
                parent_id     => $run_ord,
                run_id        => $run_ord,
                state         => 'sealed',
                started_at    => undef,
                ended_at      => undef,
                log           => $self,
                artifact_refs => $art_idx->{service}{$r->{service_id}} // {},
            );
        },
    );
}

sub collector_producers {
    my $self = shift;
    # Collectors are not a DB concept in v1; return an empty iterator.
    require App::Yath2::Log::Iterator::Producers;
    return App::Yath2::Log::Iterator::Producers->new(
        next_cb => sub { return undef },
    );
}

# }}}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Log::DB - Thin Log proxy in front of an L<App::Yath2::DB> archive.

=head1 DESCRIPTION

A consumer of L<App::Yath2::Role::Log>: a single C<App::Yath2::Log::DB>
instance binds an L<App::Yath2::DB> handle to a single archive uuid
and exposes the same archive-shaped surface every other Log backend
(L<App::Yath2::Log::Directory>, L<App::Yath2::Log::TarZIdx>,
L<App::Yath2::Log::Live>) does.

Every method here is a one-liner forwarder: read methods delegate to
the wrapped C<App::Yath2::DB> instance with this object's cached
C<uuid> prepended; the walker entry points use a uuid-scoped clone of
the underlying DB so walker state lives per-instance rather than on
the multi-archive parent. Construction is the only nontrivial step
in this class.

The C<uuid> is fixed for the object's lifetime; switch archives by
constructing a new C<App::Yath2::Log::DB> against the same C<App::Yath2::DB>.

=head1 SYNOPSIS

    use App::Yath2::DB;
    use App::Yath2::Log::DB;

    my $db = App::Yath2::DB->new(file => '/tmp/runs.yath');
    for my $uuid ($db->archives) {
        my $log = App::Yath2::Log::DB->new(db => $db, uuid => $uuid);
        my @runs = $log->runs;
        ...;
    }

L<App::Yath2::Log/new> already constructs one of these for you when
you hand it a C<file =E<gt> $path>, C<dbh =E<gt> $h>, or C<dsn =E<gt>
$d> argument; direct construction is mostly for callers who already
have an C<App::Yath2::DB> in hand.

=head1 ATTRIBUTES

=over 4

=item $db = $log->db

The wrapped L<App::Yath2::DB> instance.

=item $uuid = $log->uuid

The archive uuid this Log proxies. Fixed for the object's lifetime.

=back

=head1 METHODS

This class consumes L<App::Yath2::Role::Log>; see that role for the
contract every method below satisfies. All methods are pass-throughs
to the wrapped C<App::Yath2::DB>.

=head2 Construction

=over 4

=item $log = App::Yath2::Log::DB->new(db => $db, uuid => $uuid)

Both C<db> and C<uuid> are required. C<db> must be an
L<App::Yath2::DB> instance.

=back

=head2 Listing pass-throughs

=over 4

=item @names = $log->services($run_ord?)
=item @ords = $log->runs
=item @ords = $log->jobs($run_ord)
=item @ords = $log->tries($run_ord, $job_ord)
=item $ord = $log->last_try($run_ord, $job_ord)
=item $bool = $log->has_service($name, $run_ord?)
=item $bool = $log->has_run($run_ord)
=item $bool = $log->has_job($run_ord, $job_ord)
=item $bool = $log->has_try($run_ord, $job_ord, $try_ord)
=item @paths = $log->list_files

=back

=head2 Path / artifact handle

=over 4

=item $abs = $log->absolute_path($rel)

Croaks; DB-backed Logs do not have a per-artifact filesystem path.

=item $artifact = $log->artifacts(...)

L<App::Yath2::Log::Artifact> handle. The returned handle binds to a
uuid-scoped clone of the underlying L<App::Yath2::DB>, so its private
C<_artifact_*> calls land on C<App::Yath2::DB> directly without a
second hop through this class.

=back

=head2 Walker

Walker entry points are thin wrappers around a cached
L<App::Yath2::DB::Iterator>. The iterator is built lazily on first
use; C<reset> rewinds the cached iterator rather than allocating a new
one so callers see consistent walker state across calls.

=over 4

=item $event = $log->event

=item @events = $log->events

=item $bool = $log->end_of_events

=item $bool = $log->EOE

=item $log->reset

=back

=head2 Conversion / import

=over 4

=item $log_dir = $log->extract($dir, %opts)
=item $log->archive($out_path, %opts)
=item $aid = $log->insert($source_log, %opts)

C<insert> reverses the data flow: it calls back into the underlying
L<App::Yath2::DB> to copy a source Log's contents into this DB as a
new archive.

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
