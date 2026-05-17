package App::Yath2::DB::DBIC;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Object::HashBase qw{
    <file <dsn <user <pass <attrs <dbh
    <schema
    <flavor_override
};

use Role::Tiny::With;
with 'App::Yath2::Role::DB::Backend';

# Single-class DBIx::Class backend for yath log archives.
#
# This class consumes App::Yath2::Role::DB::Backend. Schema bootstrap
# remains share/schema/$flavor.sql-driven via the role; $schema->deploy
# is never called.

sub init {
    my $self = shift;
    require App::Yath2::DB::DBIC::Schema;

    if (defined $self->{+SCHEMA}) {
        # Caller passed a connected DBIx::Class::Schema. Keep it.
    }
    elsif (defined $self->{+DBH}) {
        my $dbh = $self->{+DBH};
        $self->{+SCHEMA} = App::Yath2::DB::DBIC::Schema->connect(sub { $dbh });
    }
    elsif (defined $self->{+DSN}) {
        $self->{+SCHEMA} = App::Yath2::DB::DBIC::Schema->connect(
            $self->{+DSN},
            $self->{+USER},
            $self->{+PASS},
            $self->{+ATTRS} // {RaiseError => 1, PrintError => 0, AutoCommit => 1},
        );
    }
    elsif (defined $self->{+FILE}) {
        my $file = $self->{+FILE};
        if (!-e $file) {
            require File::Basename;
            require File::Path;
            my $par = File::Basename::dirname($file);
            File::Path::make_path($par) if length $par && !-d $par;
        }
        $self->{+SCHEMA} = App::Yath2::DB::DBIC::Schema->connect(
            "dbi:SQLite:dbname=$file", '', '',
            {
                RaiseError     => 1,
                PrintError     => 0,
                AutoCommit     => 1,
                sqlite_unicode => 1,
            },
        );
        # SQLite open-time PRAGMAs.
        my $dbh = $self->{+SCHEMA}->storage->dbh;
        $dbh->do('PRAGMA journal_mode = WAL');
        $dbh->do('PRAGMA synchronous = NORMAL');
        $dbh->do('PRAGMA busy_timeout = 5000');
        $dbh->do('PRAGMA foreign_keys = ON');
        $dbh->do('PRAGMA temp_store = MEMORY');
    }
    else {
        croak "DBIC backend requires one of: schema, dbh, dsn, file";
    }

    # Bootstrap (idempotent): role-provided bootstrap_schema runs
    # share/schema/$flavor.sql against $self->dbh. Skipped on already-
    # populated DBs via _is_bootstrapped.
    $self->bootstrap_schema;

    return;
}

# ----- core role-required methods -----

sub flavor {
    my $self = shift;
    # Caller-supplied flavor wins (caller knows whether they're talking
    # to MySQL or MariaDB through DBD::MariaDB).
    return $self->{+FLAVOR_OVERRIDE} if defined $self->{+FLAVOR_OVERRIDE};
    # sqlt_type doesn't distinguish MariaDB from MySQL when DBD::MariaDB
    # is the underlying driver (both come back as 'MySQL'). Sniff the
    # actual server first, fall back to sqlt_type.
    my $driver;
    my $ok  = eval { $driver = $self->{+SCHEMA}->storage->dbh->{Driver}{Name}; 1 };
    my $err = $@;
    $driver //= '';
    return 'mariadb' if $driver eq 'MariaDB';
    return 'mysql'   if $driver eq 'mysql';
    my $t = $self->{+SCHEMA}->storage->sqlt_type;
    my $f = {
        SQLite     => 'sqlite',
        PostgreSQL => 'postgres',
        MySQL      => 'mysql',
        MariaDB    => 'mariadb',
    }->{$t // ''};
    croak "unsupported flavor '" . ($t // '<undef>') . "' (DBIC sqlt_type)"
        unless $f;
    return $f;
}

# Always return a live handle (DBIC's storage reconnects as needed).
# Override the slot accessor HashBase generated for `<dbh` so callers
# never hit a stale handle if storage reconnected under us.
{
    no warnings 'redefine';
    *dbh = sub { $_[0]->{+SCHEMA}->storage->dbh };
}

# Schema-bootstrap hooks (preprocess_schema_sql, _pg_server_compression,
# _server_is_mariadb, _should_skip_schema_statement) come from
# App::Yath2::Role::DB::Backend; both the SQL and DBIC backends share
# them.

# ----- Native read primitives -----
#
# UUID codec (_uuid_to_db / _uuid_from_db) and JSON helpers
# (_maybe_decode_json, _inflate_json_rows) live on
# App::Yath2::Role::DB::Backend; both backends share them.

# -- archive layer ----------------------------------------------------------

sub archive_rows {
    my $self = shift;
    my @out;
    for my $row (
        $self->{+SCHEMA}->resultset('Archive')->search(
            undef, {order_by => 'archive_id'},
        )->all
        )
    {
        push @out, {
            archive_id      => $row->archive_id,
            archive_uuid    => $self->_uuid_from_db($row->archive_uuid),
            archive_version => $row->archive_version,
            sealed_at       => $row->sealed_at,
            host            => $row->host,
            user            => $row->archive_user,
            git_sha         => $row->git_sha,
            project         => $row->project,
            yath_version    => $row->yath_version,
            meta_extras     => $self->_maybe_decode_json($row->meta_extras),
        };
    }
    return \@out;
}

sub archive_for_uuid {
    my ($self, $canon) = @_;
    return undef unless defined $canon;
    for my $row (@{$self->archive_rows}) {
        return $row if lc($row->{archive_uuid}) eq lc($canon);
    }
    return undef;
}

sub archive_count {
    my $self = shift;
    return scalar $self->{+SCHEMA}->resultset('Archive')->count;
}

# -- run / job / try / service rows ----------------------------------------

sub run_rows {
    my ($self, $aid) = @_;
    croak "archive_id required" unless defined $aid;
    my @out;
    for my $r (
        $self->{+SCHEMA}->resultset('Run')->search(
            {archive_id => $aid},
            {order_by   => 'run_ord'},
        )->all
        )
    {
        push @out, {
            run_id     => $r->run_id,
            run_ord    => $r->run_ord,
            run_uuid   => $self->_uuid_from_db($r->run_uuid),
            status     => $r->status,
            aborted    => $r->aborted   ? 1 : 0,
            timed_out  => $r->timed_out ? 1 : 0,
            project_id => $r->project_id,
        };
    }
    return \@out;
}

# Like run_rows but also returns producer-relevant columns omitted by
# run_rows: pass, exit (as run_exit), started_at, ended_at.
# Used by Log::DB producer iterators to bulk-fetch in a single query.
sub run_full_rows {
    my ($self, $aid) = @_;
    croak "archive_id required" unless defined $aid;
    my @out;
    for my $r (
        $self->{+SCHEMA}->resultset('Run')->search(
            {archive_id => $aid},
            {order_by   => 'run_ord'},
        )->all
        )
    {
        push @out, {
            run_id     => $r->run_id,
            run_ord    => $r->run_ord,
            run_uuid   => $self->_uuid_from_db($r->run_uuid),
            status     => $r->status,
            aborted    => $r->aborted   ? 1 : 0,
            timed_out  => $r->timed_out ? 1 : 0,
            project_id => $r->project_id,
            pass       => defined $r->pass ? ($r->pass ? 1 : 0) : undef,
            run_exit   => $r->run_exit,
            started_at => $r->started_at,
            ended_at   => $r->ended_at,
        };
    }
    return \@out;
}

# Fetch all job_tries for all jobs under a given run_id in a single
# query. Returns an arrayref of hashrefs with: job_try_id, job_id,
# try_ord, pass, try_exit, started_at, ended_at, status.
sub try_rows_for_run {
    my ($self, $rid) = @_;
    croak "run_id required" unless defined $rid;

    # DBIC: search job_tries joined through jobs with run_id filter.
    my @out;
    for my $jt (
        $self->{+SCHEMA}->resultset('JobTry')->search(
            {'job.run_id' => $rid},
            {
                join     => 'job',
                order_by => ['me.job_id', 'me.try_ord'],
            },
        )->all
        )
    {
        push @out, {
            job_try_id => $jt->job_try_id,
            job_id     => $jt->job_id,
            try_ord    => $jt->try_ord,
            pass       => defined $jt->pass ? ($jt->pass ? 1 : 0) : undef,
            try_exit   => $jt->try_exit,
            started_at => $jt->started_at,
            ended_at   => $jt->ended_at,
            status     => $jt->status,
        };
    }
    return \@out;
}

sub service_rows {
    my ($self, $aid, %filter) = @_;
    croak "archive_id required" unless defined $aid;
    my %where = (archive_id => $aid);
    if (exists $filter{run_id}) {
        $where{run_id} = $filter{run_id};
    }
    my @out;
    for my $r (
        $self->{+SCHEMA}->resultset('Service')->search(
            \%where, {order_by => 'service_id'},
        )->all
        )
    {
        push @out, {
            service_id => $r->service_id,
            name       => $r->name,
            run_id     => $r->run_id,
        };
    }
    return \@out;
}

sub job_rows {
    my ($self, $aid, $rid) = @_;
    croak "archive_id required" unless defined $aid;
    croak "run_id required"     unless defined $rid;
    my @out;
    for my $r (
        $self->{+SCHEMA}->resultset('Job')->search(
            {archive_id => $aid, run_id => $rid},
            {order_by   => 'job_ord'},
        )->all
        )
    {
        push @out, {
            job_id       => $r->job_id,
            job_ord      => $r->job_ord,
            test_file_id => $r->test_file_id,
        };
    }
    return \@out;
}

sub try_rows {
    my ($self, $jid) = @_;
    croak "job_id required" unless defined $jid;
    my @rows;
    for my $r (
        $self->{+SCHEMA}->resultset('JobTry')->search(
            {job_id   => $jid},
            {order_by => 'try_ord'},
        )->all
        )
    {
        push @rows, {$r->get_columns};
    }
    return $self->_inflate_json_rows(
        \@rows, [
            qw/exit_decoded plan halt
                                                 times child_times
                                                 spec_extras state_extras/
        ]
    );
}

# -- generic count / find / ensure primitives -------------------------------
#
# Public *_exists, *_id_for_*, and ensure_*_row wrappers live on
# App::Yath2::Role::DB::Backend; they delegate to these primitives.

# table → DBIC ResultSource name. Both backends share the same logical
# tables; the role uses table names because DBIC's resultset names are
# not exposed elsewhere.
my %_RS_FOR_TABLE = (
    archives          => 'Archive',
    runs              => 'Run',
    jobs              => 'Job',
    job_tries         => 'JobTry',
    services          => 'Service',
    artifacts         => 'Artifact',
    job_specs         => 'JobSpec',
    service_lifetimes => 'ServiceLifetime',
    subtests          => 'Subtest',
    projects          => 'Project',
    test_files        => 'TestFile',
);

sub _rs_for_table {
    my ($self, $table) = @_;
    my $name = $_RS_FOR_TABLE{$table}
        or croak "no DBIC resultset mapping for table '$table'";
    return $self->{+SCHEMA}->resultset($name);
}

sub _count_rows {
    my ($self, $table, %where) = @_;
    return scalar $self->_rs_for_table($table)->search(\%where)->count;
}

sub _find_one_col {
    my ($self, $table, $col, %where) = @_;
    my $row = $self->_rs_for_table($table)->search(\%where)->first;
    return undef unless $row;
    return $row->$col;
}

sub _ensure_row {
    my ($self, $table, %args) = @_;
    my $where  = $args{where}  or croak "where required";
    my $fields = $args{fields} or croak "fields required";
    my $id_col = $args{id_col} or croak "id_col required";

    my $rs       = $self->_rs_for_table($table);
    my $existing = $rs->search($where)->first;
    return $existing->$id_col if $existing;

    my $row = $rs->create($fields);
    return $row->$id_col;
}

# -- artifact rows ----------------------------------------------------------

sub artifact_rows_for_archive {
    my ($self, $aid, %opts) = @_;
    croak "archive_id required" unless defined $aid;
    my $with_payload = $opts{with_payload} ? 1 : 0;

    my $rs = $self->{+SCHEMA}->resultset('Artifact')->search(
        {'me.archive_id' => $aid},
        {
            prefetch => [
                'run',
                {service => 'run'},
                {job_try => {job => 'run'}},
            ],
            order_by => 'me.artifact_id',
        },
    );

    my @rows;
    while (my $a = $rs->next) {
        my %r = (
            artifact_id   => $a->artifact_id,
            run_id        => $a->run_id,
            service_id    => $a->service_id,
            job_try_id    => $a->job_try_id,
            artifact_kind => $a->artifact_kind,
            format        => $a->format,
            name          => $a->name,
            compressed    => $a->compressed ? 1 : 0,
            row_count     => $a->row_count,
        );
        if (my $svc = $a->service) {
            $r{service_name} = $svc->name;
            if (my $sr = $svc->run) { $r{s_run_ord} = $sr->run_ord }
        }
        if (my $rn = $a->run) {
            $r{run_ord} = $rn->run_ord;
        }
        if (my $jt = $a->job_try) {
            $r{try_ord} = $jt->try_ord;
            if (my $j = $jt->job) {
                $r{job_ord} = $j->job_ord;
                if (my $jr = $j->run) { $r{j_run_ord} = $jr->run_ord }
            }
        }
        $r{payload} = $a->payload if $with_payload;
        push @rows, \%r;
    }
    return \@rows;
}

sub artifact_row_for_scope {
    my ($self, $aid, $scope_kind, $scope_id, $kind, $name) = @_;
    croak "archive_id required"    unless defined $aid;
    croak "scope_kind required"    unless defined $scope_kind;
    croak "artifact_kind required" unless defined $kind;

    my %where = (archive_id => $aid, artifact_kind => $kind);
    if ($scope_kind eq 'run') {
        $where{run_id}     = $scope_id;
        $where{service_id} = undef;
        $where{job_try_id} = undef;
    }
    elsif ($scope_kind eq 'service') {
        $where{service_id} = $scope_id;
        $where{run_id}     = undef;
        $where{job_try_id} = undef;
    }
    elsif ($scope_kind eq 'job_try') {
        $where{job_try_id} = $scope_id;
        $where{run_id}     = undef;
        $where{service_id} = undef;
    }
    elsif ($scope_kind eq 'archive') {
        $where{run_id}     = undef;
        $where{service_id} = undef;
        $where{job_try_id} = undef;
    }
    else {
        croak "unknown scope_kind: $scope_kind";
    }
    $where{name} = defined $name ? $name : undef;

    my $row = $self->{+SCHEMA}->resultset('Artifact')->search(\%where)->first;
    return undef unless $row;

    return {
        artifact_id => $row->artifact_id,
        compressed  => $row->compressed ? 1 : 0,
        row_count   => $row->row_count,
        payload     => $row->payload,
        format      => $row->format,
    };
}

sub artifact_payload {
    my ($self, $artifact_id) = @_;
    croak "artifact_id required" unless defined $artifact_id;
    my $row = $self->{+SCHEMA}->resultset('Artifact')->find($artifact_id);
    return undef unless $row;
    return $row->payload;
}

# Sum row_count across every events artifact in this archive. Returns
# undef when no events rows exist. Croaks if any matching row has a
# NULL row_count -- that is a data-layer bug (insert side must always
# populate row_count for events artifacts).
sub artifact_event_count_for_archive {
    my ($self, $aid) = @_;
    croak "archive_id required" unless defined $aid;

    my $rs = $self->{+SCHEMA}->resultset('Artifact')->search(
        {archive_id => $aid, artifact_kind => 'events'},
    );

    my $null_rows = $rs->search({row_count => undef})->count;
    croak "events artifact rows with NULL row_count in archive $aid (data-layer bug)"
        if $null_rows;

    return $rs->get_column('row_count')->sum;
}

# -- spec / report data layer ----------------------------------------------

sub job_spec_rows {
    my ($self, $jid, $try_ord) = @_;
    croak "job_id required" unless defined $jid;
    my @rows;
    for my $r (
        $self->{+SCHEMA}->resultset('JobSpec')->search(
            {job_id   => $jid},
            {order_by => 'job_spec_id'},
        )->all
        )
    {
        push @rows, {$r->get_columns};
    }
    return $self->_inflate_json_rows(\@rows, [qw/features switches extras/]);
}

sub service_lifetime_rows {
    my ($self, $sid) = @_;
    croak "service_id required" unless defined $sid;
    my @rows;
    for my $r (
        $self->{+SCHEMA}->resultset('ServiceLifetime')->search(
            {service_id => $sid},
            {order_by   => 'lifetime_ord'},
        )->all
        )
    {
        push @rows, {$r->get_columns};
    }
    return $self->_inflate_json_rows(
        \@rows, [
            qw/exit_decoded times
                                                 child_times spec_extras
                                                 state_extras/
        ]
    );
}

sub subtest_rows {
    my ($self, $jtid) = @_;
    croak "job_try_id required" unless defined $jtid;
    my @out;
    for my $r (
        $self->{+SCHEMA}->resultset('Subtest')->search(
            {job_try_id => $jtid},
            {order_by   => 'ord'},
        )->all
        )
    {
        my %h = $r->get_columns;
        push @out, \%h;
    }
    return \@out;
}

# -- write primitives -------------------------------------------------------
#
# Mirrors App::Yath2::DB::SQL's write API on the DBIC layer. All input
# args are canonical Perl values (UUIDs as 36-char lowercase hex; JSON
# columns as decoded refs; datetimes as ISO-8601 strings; payloads as
# raw bytes). Per-flavor bind concerns: UUID columns route through
# _uuid_to_db; payload (BYTEA on Postgres / LONGBLOB on MySQL /
# BLOB on SQLite) is bound via $schema->storage->dbh_do for the row
# UPDATE / INSERT to ensure DBD::Pg / DBD::MariaDB get the correct type
# hints (DBIC's create()/update() does not always set the right bind
# type when the Result column is declared 'blob' but the underlying
# column is BYTEA / BINARY). Because DBIC and the SQL backend both
# share the same dbh shape, we delegate the actual DB call through a
# parallel SQL backend instance so flavor-specific bind code lives in
# exactly one place. The shared App::Yath2::DB::SQL instance is bound
# to the same dbh as our DBIC schema, so transactional state stays
# consistent.

sub _shared_sql_backend {
    my $self = shift;
    return $self->{__shared_sql} //= do {
        require App::Yath2::DB::SQL;
        # Cannot pass `flavor => ...` to App::Yath2::DB::SQL->new because
        # SQL.pm's HashBase declares it as a +flavor (reader, no
        # constructor accept). Set it manually after construction.
        my $obj = App::Yath2::DB::SQL->new(dbh => $self->dbh);
        $obj->{App::Yath2::DB::SQL::FLAVOR()} = $self->flavor;
        $obj;
    };
}

sub archive_create {
    my ($self, $fields) = @_;
    return $self->_shared_sql_backend->archive_create($fields);
}

sub mark_sealed {
    my ($self, $aid, $when) = @_;
    croak "archive_id required" unless defined $aid;
    $self->{+SCHEMA}->resultset('Archive')->search({archive_id => $aid})->update({sealed_at => $when});
    return;
}

# Public ensure_*_row methods (project, test_file, service, job,
# job_try) live on App::Yath2::Role::DB::Backend, which calls
# _ensure_row above. ensure_run_row routes through the shared SQL
# backend because the row needs a per-flavor UUID bind.

sub ensure_run_row {
    my ($self, $aid, $run_ord, $project_id) = @_;
    return $self->_shared_sql_backend->ensure_run_row($aid, $run_ord, $project_id);
}

sub artifact_create {
    my ($self, $fields) = @_;
    # The artifact INSERT is the most flavor-sensitive write (UUID +
    # BYTEA + datetime). Route through the shared SQL backend so all
    # flavor-specific bind logic lives in one place and DBIC consumers
    # don't have to second-guess Result column data_type declarations.
    return $self->_shared_sql_backend->artifact_create($fields);
}

sub artifact_update {
    my ($self, $artifact_id, $fields) = @_;
    return $self->_shared_sql_backend->artifact_update($artifact_id, $fields);
}

sub job_spec_create {
    my ($self, $job_id, $fields) = @_;
    # Route through the shared SQL backend; same Postgres jsonb-cast
    # reason as service_lifetime_create.
    return $self->_shared_sql_backend->job_spec_create($job_id, $fields);
}

sub service_lifetime_create {
    my ($self, $service_id, $fields) = @_;
    # Route through the shared SQL backend so JSON column binds (jsonb
    # on Postgres) get the correct cast hint at execute time. DBIC's
    # generic create() binds 'blob'-declared columns as bytea, which
    # the server refuses to coerce into jsonb on Postgres.
    return $self->_shared_sql_backend->service_lifetime_create($service_id, $fields);
}

sub subtest_create {
    my ($self, $job_try_id, $fields) = @_;
    croak "job_try_id required"     unless defined $job_try_id;
    croak "fields hashref required" unless ref($fields) eq 'HASH';
    croak "name required"           unless defined $fields->{name};
    croak "ord required"            unless defined $fields->{ord};

    my %row = (
        job_try_id => $job_try_id,
        name       => $fields->{name},
        pass       => $fields->{pass} ? 1 : 0,
        ord        => $fields->{ord},
    );
    for my $c (qw/count_pass count_fail/) {
        $row{$c} = $fields->{$c} if exists $fields->{$c};
    }
    my $obj = $self->{+SCHEMA}->resultset('Subtest')->create(\%row);
    return $obj->subtest_id;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::DB::DBIC - DBIx::Class backend for L<App::Yath2::DB>.

=head1 DESCRIPTION

Single-class implementation of L<App::Yath2::Role::DB::Backend>.
Wraps an L<App::Yath2::DB::DBIC::Schema> instance and exposes the
role's reader / writer surface. The corresponding raw-DBI sibling is
L<App::Yath2::DB::SQL>; both are interchangeable behind L<App::Yath2::DB>.

Schema bootstrap is driven by F<share/schema/$flavor.sql> via
L<App::Yath2::Role::DB::Backend>; C<DBIC-E<gt>deploy> is never called.

End users construct via L<App::Yath2::DB> with C<backend =E<gt>
'dbic'>; this class is rarely instantiated directly except by tests.

=head1 SYNOPSIS

    use App::Yath2::DB;

    my $db = App::Yath2::DB->new(
        file    => '/tmp/run.yath',
        backend => 'dbic',
    );

    # Caller-supplied schema:
    my $schema = App::Yath2::DB::DBIC::Schema->connect(...);
    my $db = App::Yath2::DB->new(schema => $schema);

=head1 ATTRIBUTES

=over 4

=item $val = $self->file
=item $val = $self->dsn
=item $val = $self->user
=item $val = $self->pass
=item $val = $self->attrs
=item $val = $self->dbh

DBI-style connection attributes; the DBIC schema is built from these
when one was not supplied directly.

=item $schema = $self->schema

The wrapped L<DBIx::Class::Schema>.

=item $val = $self->flavor_override

Optional flavor override; when set, takes precedence over storage
detection. The DBD::MariaDB driver speaks both MySQL and MariaDB, so
flavor() cannot reliably distinguish them from the driver name alone --
the caller-supplied override is the only source of truth in that case.

=back

=head1 METHODS

The row-level primitive surface required by
L<App::Yath2::Role::DB::Backend>. Where the role spec covers the
contract, only DBIC-specific notes appear below.

=head2 Lifecycle

=over 4

=item $self->init

Object construction hook. Connects the schema (if not supplied
directly) and runs C<bootstrap_schema>.

=item $flavor = $self->flavor

Detect flavor from the C<schema>'s storage driver class, the DSN, or
the explicit C<flavor_override>.

=back

Schema-bootstrap hooks (C<preprocess_schema_sql>,
C<_pg_server_compression>, C<_server_is_mariadb>,
C<_should_skip_schema_statement>) come from
L<App::Yath2::Role::DB::Backend>; consult that role for the contract.

=head2 Archive rows

=over 4

=item $rows = $self->archive_rows
=item $row = $self->archive_for_uuid($canon)
=item $count = $self->archive_count

=back

=head2 Per-archive row primitives

=over 4

=item $rows = $self->run_rows($aid)
=item $rows = $self->service_rows($aid, %opts)
=item $rows = $self->job_rows($aid, $run_id)
=item $rows = $self->try_rows($job_id)
=item $rows = $self->job_spec_rows($aid, $run_id, $job_ord)
=item $rows = $self->service_lifetime_rows($service_id)
=item $rows = $self->subtest_rows($job_try_id)

=back

=head2 Existence checks

=over 4

=item $bool = $self->run_exists($aid, $run_ord)
=item $bool = $self->job_exists($aid, $rid, $job_ord)
=item $bool = $self->try_exists($jid, $try_ord)
=item $bool = $self->service_exists($aid, $name, $rid_or_undef)

=back

=head2 Id resolution

=over 4

=item $id = $self->run_id_for_ord($aid, $run_ord)
=item $id = $self->job_id_for_ord($aid, $rid, $job_ord)
=item $id = $self->try_id_for_ord($jid, $try_ord)
=item $id = $self->service_id_for_name($aid, $name, $rid_or_undef)

=back

=head2 Artifact rows

=over 4

=item $rows = $self->artifact_rows_for_archive($aid, %opts)
=item $row = $self->artifact_row_for_scope($aid, $scope_kind, $scope_id, $artifact_kind, $name)
=item $bytes = $self->artifact_payload($artifact_id)
=item $sum = $self->artifact_event_count_for_archive($aid)

=back

=head2 Write primitives

The data layer in L<App::Yath2::DB> drives these during inserts and
artifact saves.

=over 4

=item $aid = $self->archive_create($fields)
=item $self->mark_sealed($archive_id, $when)

=item $id = $self->ensure_project_row($name)
=item $id = $self->ensure_test_file_row($project_id, $relative)
=item $id = $self->ensure_run_row($aid, $run_ord, $project_id)
=item $id = $self->ensure_service_row($aid, $name, $rid_or_undef)
=item $id = $self->ensure_job_row($aid, $rid, $job_ord, $test_file_id)
=item $id = $self->ensure_job_try_row($jid, $try_ord)

Create-or-find primitives. Idempotent.

=item $id = $self->artifact_create($fields)
=item $self->artifact_update($artifact_id, $fields)
=item $self->job_spec_create($job_id, $fields)
=item $self->service_lifetime_create($service_id, $fields)
=item $self->subtest_create($job_try_id, $fields)

Pure inserts / updates. Field shaping is the data layer's job.

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
