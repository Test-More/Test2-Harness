package App::Yath2::DB::SQL;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use File::Basename qw/dirname/;
use File::Path qw/make_path/;

use Test2::Util::UUID qw/gen_uuid/;

use Object::HashBase qw{
    <dsn <user <pass <attrs <dbh <file
    +flavor
};

use Role::Tiny::With;
with 'App::Yath2::Role::DB::Backend';

# Single-class raw-DBI backend implementing
# App::Yath2::Role::DB::Backend. Flavor differences (UUID bind shape,
# payload binding, MariaDB trigger skip) live inside individual methods
# rather than per-flavor subclasses.

sub init {
    my $self = shift;

    croak "App::Yath2::DB::SQL requires one of: file, dbh, dsn"
        unless defined $self->{+FILE}
        || defined $self->{+DBH}
        || defined $self->{+DSN};

    # Connect (lazily; bootstrap will use $self->dbh).
    $self->dbh;
    $self->_apply_session_state;
    $self->bootstrap_schema;

    return;
}

# -- connection / dbh / flavor -----------------------------------------------

# Always return a live handle. HashBase's read accessor returns the slot
# verbatim; override so callers never hit a stale undef when only one of
# {file,dsn} was supplied.
{
    no warnings 'redefine';
    *dbh = sub {
        my $self = shift;
        return $self->{+DBH} //= $self->_connect_dbh;
    };
}

sub flavor {
    my $self = shift;
    return $self->{+FLAVOR} //= $self->_detect_flavor;
}

sub _detect_flavor {
    my $self = shift;

    if (defined $self->{+DSN}) {
        my $dsn = $self->{+DSN};
        return 'postgres' if $dsn =~ /^dbi:Pg:/i;
        return 'mariadb'  if $dsn =~ /^dbi:MariaDB:/i;
        return 'mysql'    if $dsn =~ /^dbi:mysql:/i;
        return 'sqlite'   if $dsn =~ /^dbi:SQLite:/i;
    }

    if (defined $self->{+DBH}) {
        my $name = $self->{+DBH}{Driver}{Name} // '';
        return 'sqlite'   if $name eq 'SQLite';
        return 'postgres' if $name eq 'Pg';
        return 'mariadb'  if $name eq 'MariaDB';
        return 'mysql'    if $name eq 'mysql';
    }

    return 'sqlite' if defined $self->{+FILE};

    croak "could not detect SQL backend flavor (no file/dsn/dbh hint)";
}

sub _connect_dbh {
    my $self = shift;
    require DBI;

    my $flavor = $self->flavor;

    my $dsn   = $self->_resolve_or_build_dsn;
    my $user  = $self->{+USER};
    my $pass  = $self->{+PASS};
    my $attrs = $self->{+ATTRS} || {};

    return $self->_connect_sqlite($dsn, $user, $pass, $attrs)   if $flavor eq 'sqlite';
    return $self->_connect_postgres($dsn, $user, $pass, $attrs) if $flavor eq 'postgres';
    return $self->_connect_mysql_family($flavor, $dsn, $user, $pass, $attrs)
        if $flavor eq 'mariadb' || $flavor eq 'mysql';

    croak "unsupported SQL backend flavor: $flavor";
}

# Return the configured DSN or, when only +FILE was supplied, derive a
# sqlite DSN (and stash it in +DSN). Croaks when neither is available.
sub _resolve_or_build_dsn {
    my $self = shift;
    my $dsn  = $self->{+DSN};
    return $dsn if defined $dsn;

    my $file = $self->{+FILE};
    croak "no file or dsn provided" unless defined $file;

    # File path implies sqlite. Make the parent dir on the fly so
    # callers can pass a path under a non-existent tempdir.
    if (!-e $file) {
        my $par = dirname($file);
        make_path($par) if length $par && !-d $par;
    }

    $dsn = "dbi:SQLite:dbname=$file";
    $self->{+DSN} = $dsn;
    return $dsn;
}

# Open a sqlite DBI handle and apply the open-time PRAGMAs that the
# schema relies on.
sub _connect_sqlite {
    my ($self, $dsn, $user, $pass, $attrs) = @_;
    my $dbh = DBI->connect(
        $dsn, $user, $pass, {
            RaiseError     => 1,
            PrintError     => 0,
            AutoCommit     => 1,
            sqlite_unicode => 1,
            %$attrs,
        }
    ) or croak "DBI->connect $dsn: $DBI::errstr";

    # Open-time PRAGMAs (per share/schema/SCHEMA.md §8).
    $dbh->do('PRAGMA journal_mode = WAL');
    $dbh->do('PRAGMA synchronous = NORMAL');
    $dbh->do('PRAGMA busy_timeout = 5000');
    $dbh->do('PRAGMA foreign_keys = ON');
    $dbh->do('PRAGMA temp_store = MEMORY');

    return $dbh;
}

# Open a postgres DBI handle (requires DBD::Pg).
sub _connect_postgres {
    my ($self, $dsn, $user, $pass, $attrs) = @_;
    my $ok  = eval { require DBD::Pg; 1 };
    my $err = $@;
    croak "install DBD::Pg to use the postgres backend: $err" unless $ok;

    my $dbh = DBI->connect(
        $dsn, $user, $pass, {
            RaiseError     => 1,
            PrintError     => 0,
            AutoCommit     => 1,
            pg_enable_utf8 => 1,
            %$attrs,
        }
    ) or croak "DBI->connect $dsn: $DBI::errstr";

    return $dbh;
}

# Open a MySQL / MariaDB DBI handle (requires DBD::MariaDB).
sub _connect_mysql_family {
    my ($self, $flavor, $dsn, $user, $pass, $attrs) = @_;
    my $ok  = eval { require DBD::MariaDB; 1 };
    my $err = $@;
    croak "install DBD::MariaDB to use the $flavor backend: $err" unless $ok;

    my $dbh = DBI->connect(
        $dsn, $user, $pass, {
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,
            %$attrs,
        }
    ) or croak "DBI->connect $dsn: $DBI::errstr";

    return $dbh;
}

# Apply per-flavor session state on a fresh connection. Currently only
# MySQL and MariaDB need this (ANSI_QUOTES so the shared SQL's "user" /
# "exit" double-quoted identifiers parse as identifier quotes, not
# string literals).
sub _apply_session_state {
    my $self   = shift;
    my $flavor = $self->flavor;
    return unless $flavor eq 'mariadb' || $flavor eq 'mysql';
    my $dbh = $self->{+DBH} or return;
    $dbh->do(q{SET SESSION sql_mode = CONCAT(@@sql_mode, ',ANSI_QUOTES')});
    return;
}

# Schema-bootstrap hooks (preprocess_schema_sql, _pg_server_compression,
# _server_is_mariadb, _should_skip_schema_statement) live on
# App::Yath2::Role::DB::Backend so the SQL and DBIC backends share the
# same flavor-detection / Postgres-compression-probe logic.

# -- codec primitives --------------------------------------------------------
#
# All public read primitives speak canonical Perl values; callers never
# see flavor-native blobs/strings. These private helpers translate at
# the bind / fetch boundary.
#
# Canonical UUID form is 36-char lowercase hex.
# Canonical JSON form is decoded Perl hashref / arrayref.
# Canonical payload form is raw bytes (zstd-encoded if compressed=1).

# UUID codec (_uuid_to_db / _uuid_from_db) lives on
# App::Yath2::Role::DB::Backend; both backends share it.

# Bind a canonical UUID value at $idx with the right driver-side type
# hint (BINARY for mysql; otherwise plain bind).
sub _bind_uuid {
    my ($self, $sth, $idx, $canon) = @_;
    require DBI;
    my $flavor  = $self->flavor;
    my $db_form = $self->_uuid_to_db($canon);
    if ($flavor eq 'mysql') {
        $sth->bind_param($idx, $db_form, DBI::SQL_BINARY());
    }
    else {
        $sth->bind_param($idx, $db_form);
    }
    return;
}

# Bind a payload (raw bytes) at $idx. MySQL/MariaDB need SQL_BLOB so
# DBD::MariaDB does not UTF-8-mangle the bytes; Postgres needs PG_BYTEA;
# SQLite is identity.
sub _bind_payload {
    my ($self, $sth, $idx, $bytes) = @_;
    my $flavor = $self->flavor;
    if ($flavor eq 'postgres') {
        require DBD::Pg;
        $sth->bind_param($idx, $bytes, {pg_type => DBD::Pg::PG_BYTEA()});
        return;
    }
    if ($flavor eq 'mysql' || $flavor eq 'mariadb') {
        require DBI;
        $sth->bind_param($idx, $bytes, DBI::SQL_BLOB());
        return;
    }
    $sth->bind_param($idx, $bytes);
    return;
}

# DBD::Pg returns BYTEA columns as raw bytes by default on fetch
# (PG_BYTEA bind hint is for the bind side, not fetch). SQLite /
# MariaDB / MySQL hand back the bytes verbatim too. This hook stays
# as identity; future flavors that need a fetch-side decode can
# override.
sub _payload_to_bytes {
    my ($self, $val) = @_;
    return $val;
}

# JSON helpers (_maybe_decode_json / _maybe_encode_json /
# _inflate_json_rows) live on App::Yath2::Role::DB::Backend.

# UUID bind hint for selectrow lookups. MySQL needs SQL_BINARY; others
# bind the canonical-form result of _uuid_to_db verbatim.
sub _uuid_lookup_bind {
    my ($self, $canon) = @_;
    require DBI;
    my $flavor  = $self->flavor;
    my $db_form = $self->_uuid_to_db($canon);
    return ($db_form, $flavor eq 'mysql' ? DBI::SQL_BINARY() : ());
}

# Quote the keyword-clashing 'user' column. Default ANSI double-quote;
# MySQL/MariaDB sessions enabled ANSI_QUOTES on connect so this stays
# valid across all four flavors.
sub _quote_user_col { '"user"' }

# -- archive layer -----------------------------------------------------------

sub archive_rows {
    my $self = shift;
    my $dbh  = $self->dbh;

    my $user_col = $self->_quote_user_col;
    my $rows     = $dbh->selectall_arrayref(
        qq{
        SELECT archive_id, archive_uuid, archive_version, sealed_at,
               host, $user_col AS user, git_sha, project, yath_version,
               meta_extras
          FROM archives
         ORDER BY archive_id
    }, {Slice => {}}
    );

    my @out;
    for my $r (@$rows) {
        push @out, {
            archive_id      => $r->{archive_id},
            archive_uuid    => $self->_uuid_from_db($r->{archive_uuid}),
            archive_version => $r->{archive_version},
            sealed_at       => $r->{sealed_at},
            host            => $r->{host},
            user            => $r->{user},
            git_sha         => $r->{git_sha},
            project         => $r->{project},
            yath_version    => $r->{yath_version},
            meta_extras     => $self->_maybe_decode_json($r->{meta_extras}),
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
    my ($n) = $self->dbh->selectrow_array(q{SELECT count(*) FROM archives});
    return $n // 0;
}

# -- run / job / try / service rows -----------------------------------------

sub run_rows {
    my ($self, $aid) = @_;
    croak "archive_id required" unless defined $aid;
    my $dbh  = $self->dbh;
    my $rows = $dbh->selectall_arrayref(
        q{
        SELECT run_id, run_ord, run_uuid, status, aborted, timed_out, project_id
          FROM runs
         WHERE archive_id = ?
         ORDER BY run_ord
    }, {Slice => {}}, $aid
    );

    my @out;
    for my $r (@$rows) {
        push @out, {
            run_id     => $r->{run_id},
            run_ord    => $r->{run_ord},
            run_uuid   => $self->_uuid_from_db($r->{run_uuid}),
            status     => $r->{status},
            aborted    => $r->{aborted}   ? 1 : 0,
            timed_out  => $r->{timed_out} ? 1 : 0,
            project_id => $r->{project_id},
        };
    }
    return \@out;
}

# Like run_rows but also returns the producer-relevant columns that
# run_rows omits: pass, exit (as run_exit), started_at, ended_at.
# Used by Log::DB producer iterators to bulk-fetch all run data in
# a single query and avoid per-run round-trips.
sub run_full_rows {
    my ($self, $aid) = @_;
    croak "archive_id required" unless defined $aid;
    my $dbh  = $self->dbh;
    my $rows = $dbh->selectall_arrayref(
        q{
        SELECT run_id, run_ord, run_uuid, status,
               aborted, timed_out, project_id,
               pass, "exit", started_at, ended_at
          FROM runs
         WHERE archive_id = ?
         ORDER BY run_ord
    }, {Slice => {}}, $aid
    );

    my @out;
    for my $r (@$rows) {
        push @out, {
            run_id     => $r->{run_id},
            run_ord    => $r->{run_ord},
            run_uuid   => $self->_uuid_from_db($r->{run_uuid}),
            status     => $r->{status},
            aborted    => $r->{aborted}   ? 1 : 0,
            timed_out  => $r->{timed_out} ? 1 : 0,
            project_id => $r->{project_id},
            pass       => defined $r->{pass} ? ($r->{pass} ? 1 : 0) : undef,
            run_exit   => $r->{exit},
            started_at => $r->{started_at},
            ended_at   => $r->{ended_at},
        };
    }
    return \@out;
}

# Fetch all job_tries for all jobs under a given run_id in a single
# query. Returns an arrayref of hashrefs with: job_try_id, job_id,
# try_ord, pass, exit (as try_exit), started_at, ended_at, status.
# Used by Log::DB::job_producers to bulk-fetch try data.
sub try_rows_for_run {
    my ($self, $rid) = @_;
    croak "run_id required" unless defined $rid;
    my $rows = $self->dbh->selectall_arrayref(
        q{
        SELECT jt.job_try_id, jt.job_id, jt.try_ord,
               jt.pass, jt.exit, jt.started_at, jt.ended_at, jt.status
          FROM job_tries jt
          JOIN jobs j ON j.job_id = jt.job_id
         WHERE j.run_id = ?
         ORDER BY jt.job_id, jt.try_ord
    }, {Slice => {}}, $rid
    );

    return [
        map {
            +{
                job_try_id => $_->{job_try_id},
                job_id     => $_->{job_id},
                try_ord    => $_->{try_ord},
                pass       => defined $_->{pass} ? ($_->{pass} ? 1 : 0) : undef,
                try_exit   => $_->{exit},
                started_at => $_->{started_at},
                ended_at   => $_->{ended_at},
                status     => $_->{status},
            }
        } @$rows
    ];
}

sub service_rows {
    my ($self, $aid, %filter) = @_;
    croak "archive_id required" unless defined $aid;
    my $dbh = $self->dbh;

    my @bind = ($aid);
    my $sql  = q{
        SELECT service_id, name, run_id
          FROM services
         WHERE archive_id = ?
    };
    if (exists $filter{run_id}) {
        if (defined $filter{run_id}) {
            $sql .= ' AND run_id = ?';
            push @bind, $filter{run_id};
        }
        else {
            $sql .= ' AND run_id IS NULL';
        }
    }
    $sql .= ' ORDER BY service_id';

    my $rows = $dbh->selectall_arrayref($sql, {Slice => {}}, @bind);
    return [
        map {
            +{
                service_id => $_->{service_id},
                name       => $_->{name},
                run_id     => $_->{run_id},
            }
        } @$rows
    ];
}

sub job_rows {
    my ($self, $aid, $run_id) = @_;
    croak "archive_id required" unless defined $aid;
    croak "run_id required"     unless defined $run_id;
    my $dbh  = $self->dbh;
    my $rows = $dbh->selectall_arrayref(
        q{
        SELECT job_id, job_ord, test_file_id
          FROM jobs
         WHERE archive_id = ? AND run_id = ?
         ORDER BY job_ord
    }, {Slice => {}}, $aid, $run_id
    );
    return [
        map {
            +{
                job_id       => $_->{job_id},
                job_ord      => $_->{job_ord},
                test_file_id => $_->{test_file_id},
            }
        } @$rows
    ];
}

sub try_rows {
    my ($self, $jid) = @_;
    croak "job_id required" unless defined $jid;
    my $rows = $self->dbh->selectall_arrayref(
        q{
        SELECT *
          FROM job_tries
         WHERE job_id = ?
         ORDER BY try_ord
    }, {Slice => {}}, $jid
    );

    return $self->_inflate_json_rows(
        $rows, [
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

# Build a "WHERE k = ? AND ..." fragment from a hash. undef values
# become "k IS NULL" (with no bind). Returns ($where_sql, @bind).
sub _build_where_sql {
    my ($self, $where) = @_;
    my @cols;
    my @bind;
    for my $k (sort keys %$where) {
        my $v = $where->{$k};
        if (defined $v) { push @cols, "$k = ?"; push @bind, $v; }
        else            { push @cols, "$k IS NULL"; }
    }
    my $sql = @cols ? join(' AND ', @cols) : '1=1';
    return ($sql, @bind);
}

sub _count_rows {
    my ($self, $table, %where) = @_;
    my ($where_sql, @bind) = $self->_build_where_sql(\%where);
    my ($n) = $self->dbh->selectrow_array(
        "SELECT count(*) FROM $table WHERE $where_sql",
        undef, @bind,
    );
    return $n // 0;
}

sub _find_one_col {
    my ($self, $table, $col, %where) = @_;
    my ($where_sql, @bind) = $self->_build_where_sql(\%where);
    my ($val) = $self->dbh->selectrow_array(
        "SELECT $col FROM $table WHERE $where_sql",
        undef, @bind,
    );
    return $val;
}

# Find-or-insert. Returns the existing row's id_col when one matches
# %{$args{where}}, otherwise inserts %{$args{fields}} and returns the
# new id (via _last_insert_id).
sub _ensure_row {
    my ($self, $table, %args) = @_;
    my $where  = $args{where}  or croak "where required";
    my $fields = $args{fields} or croak "fields required";
    my $id_col = $args{id_col} or croak "id_col required";

    if (defined(my $id = $self->_find_one_col($table, $id_col, %$where))) {
        return $id;
    }

    my @keys         = sort keys %$fields;
    my $placeholders = join(', ', ('?') x scalar(@keys));
    my $cols         = join(', ', @keys);
    my $sql          = "INSERT INTO $table ($cols) VALUES ($placeholders)";
    $self->dbh->do($sql, undef, map { $fields->{$_} } @keys);
    return $self->_last_insert_id($table, $id_col);
}

# -- artifact rows ----------------------------------------------------------

sub artifact_rows_for_archive {
    my ($self, $aid, %opts) = @_;
    croak "archive_id required" unless defined $aid;
    my $with_payload = $opts{with_payload} ? 1 : 0;
    my $dbh          = $self->dbh;

    # Postgres needs a typed bytea fetch when payloads are requested;
    # other flavors return bytes verbatim. Build the SELECT with or
    # without the payload column accordingly.
    my $extra = $with_payload ? ', a.payload' : '';
    my $sql   = qq{
        SELECT a.artifact_id,
               a.run_id, a.service_id, a.job_try_id,
               a.artifact_kind, a.format, a.name, a.compressed,
               a.row_count,
               s.name  AS service_name,
               sr.run_ord AS s_run_ord,
               r.run_ord  AS run_ord,
               t.try_ord  AS try_ord,
               j.job_ord  AS job_ord,
               jr.run_ord AS j_run_ord$extra
          FROM artifacts a
          LEFT JOIN services  s  ON a.service_id = s.service_id
          LEFT JOIN runs      sr ON s.run_id     = sr.run_id
          LEFT JOIN runs      r  ON a.run_id     = r.run_id
          LEFT JOIN job_tries t  ON a.job_try_id = t.job_try_id
          LEFT JOIN jobs      j  ON t.job_id     = j.job_id
          LEFT JOIN runs      jr ON j.run_id     = jr.run_id
         WHERE a.archive_id = ?
         ORDER BY a.artifact_id
    };

    my $rows = $dbh->selectall_arrayref($sql, {Slice => {}}, $aid);

    if ($with_payload) {
        for my $r (@$rows) {
            $r->{payload}    = $self->_payload_to_bytes($r->{payload});
            $r->{compressed} = $r->{compressed} ? 1 : 0;
        }
    }
    else {
        for my $r (@$rows) {
            $r->{compressed} = $r->{compressed} ? 1 : 0;
        }
    }
    return $rows;
}

sub artifact_row_for_scope {
    my ($self, $aid, $scope_kind, $scope_id, $kind, $name) = @_;
    croak "archive_id required"    unless defined $aid;
    croak "scope_kind required"    unless defined $scope_kind;
    croak "artifact_kind required" unless defined $kind;

    my ($scope_clause, @scope_bind) = $self->_scope_where_clause($scope_kind, $scope_id);

    my $sql;
    my @bind;
    if (defined $name) {
        $sql = qq{
            SELECT artifact_id, compressed, row_count, payload, format
              FROM artifacts
             WHERE archive_id = ? AND $scope_clause
               AND artifact_kind = ? AND name = ?
        };
        @bind = ($aid, @scope_bind, $kind, $name);
    }
    else {
        $sql = qq{
            SELECT artifact_id, compressed, row_count, payload, format
              FROM artifacts
             WHERE archive_id = ? AND $scope_clause
               AND artifact_kind = ? AND name IS NULL
        };
        @bind = ($aid, @scope_bind, $kind);
    }

    my $dbh = $self->dbh;
    my $row = $dbh->selectrow_hashref($sql, undef, @bind);
    return undef unless $row;

    return {
        artifact_id => $row->{artifact_id},
        compressed  => $row->{compressed} ? 1 : 0,
        row_count   => $row->{row_count},
        payload     => $self->_payload_to_bytes($row->{payload}),
        format      => $row->{format},
    };
}

sub artifact_payload {
    my ($self, $artifact_id) = @_;
    croak "artifact_id required" unless defined $artifact_id;
    my $dbh = $self->dbh;
    my ($bytes) = $dbh->selectrow_array(
        q{SELECT payload FROM artifacts WHERE artifact_id = ?},
        undef, $artifact_id,
    );
    return $self->_payload_to_bytes($bytes);
}

# Sum row_count across every events artifact in this archive. Returns
# undef when no events rows exist. Croaks if any matching row has a
# NULL row_count -- that is a data-layer bug (insert side must always
# populate row_count for events artifacts).
sub artifact_event_count_for_archive {
    my ($self, $aid) = @_;
    croak "archive_id required" unless defined $aid;
    my $dbh = $self->dbh;

    my ($null_rows) = $dbh->selectrow_array(
        q{SELECT COUNT(*) FROM artifacts
           WHERE archive_id = ? AND artifact_kind = 'events' AND row_count IS NULL},
        undef, $aid,
    );
    croak "events artifact rows with NULL row_count in archive $aid (data-layer bug)"
        if $null_rows;

    my ($sum) = $dbh->selectrow_array(
        q{SELECT SUM(row_count) FROM artifacts
           WHERE archive_id = ? AND artifact_kind = 'events'},
        undef, $aid,
    );
    return $sum;
}

# -- spec / report data layer ----------------------------------------------

sub job_spec_rows {
    my ($self, $jid, $try_ord) = @_;
    croak "job_id required" unless defined $jid;

    # job_specs has a UNIQUE(job_id) constraint -- one row per job, not
    # per try. The $try_ord arg exists for symmetry with future
    # primitives that want to filter by try; here it is accepted but
    # has no effect on which rows match (job_specs is the per-job
    # spec; per-try spec lives elsewhere).
    my $rows = $self->dbh->selectall_arrayref(
        q{SELECT * FROM job_specs WHERE job_id = ? ORDER BY job_spec_id},
        {Slice => {}}, $jid,
    );

    return $self->_inflate_json_rows($rows, [qw/features switches extras/]);
}

sub service_lifetime_rows {
    my ($self, $sid) = @_;
    croak "service_id required" unless defined $sid;
    my $rows = $self->dbh->selectall_arrayref(
        q{
        SELECT * FROM service_lifetimes
         WHERE service_id = ?
         ORDER BY lifetime_ord
    }, {Slice => {}}, $sid
    );

    return $self->_inflate_json_rows(
        $rows, [
            qw/exit_decoded times
                                                child_times spec_extras
                                                state_extras/
        ]
    );
}

sub subtest_rows {
    my ($self, $jtid) = @_;
    croak "job_try_id required" unless defined $jtid;
    my $dbh  = $self->dbh;
    my $rows = $dbh->selectall_arrayref(
        q{
        SELECT * FROM subtests
         WHERE job_try_id = ?
         ORDER BY ord
    }, {Slice => {}}, $jtid
    );
    # subtests has no JSON columns at present.
    return $rows;
}

# -- write primitives -------------------------------------------------------
#
# All write primitives accept canonical Perl values from the data layer
# (UUIDs as 36-char lowercase hex; JSON as decoded Perl refs; datetimes
# as ISO-8601 strings; payloads as raw bytes). Each method translates
# to flavor-native bind shapes here at the boundary; the data layer
# never sees flavor-native blobs / packed bytes / native JSON strings.

# Postgres uses RETURNING to grab the new id; everyone else uses DBI's
# last_insert_id with table + col.
sub _last_insert_id {
    my ($self, $table, $col) = @_;
    my $dbh = $self->dbh;
    if ($self->flavor eq 'postgres') {
        return $dbh->last_insert_id(undef, undef, $table, undef);
    }
    return $dbh->last_insert_id(undef, undef, $table, $col);
}

# Bind a UUID column at $idx with the right driver-side type hint.
# Mirrors _bind_uuid; named differently to make INSERT-side intent clear.
sub _bind_uuid_param {
    my ($self, $sth, $idx, $canon) = @_;
    $self->_bind_uuid($sth, $idx, $canon);
    return;
}

# -- archive layer ----------------------------------------------------------

sub archive_create {
    my ($self, $fields) = @_;
    croak "archive_create requires a hashref of fields"
        unless ref($fields) eq 'HASH';
    croak "archive_uuid required"    unless defined $fields->{archive_uuid};
    croak "archive_version required" unless defined $fields->{archive_version};

    require DBI;
    my $dbh    = $self->dbh;
    my $flavor = $self->flavor;

    my $extras_json = $self->_maybe_encode_json($fields->{meta_extras});
    my $user_col    = $self->_quote_user_col;

    my $sth = $dbh->prepare(qq{
        INSERT INTO archives
            (archive_uuid, archive_version, sealed_at,
             host, $user_col, git_sha, project, yath_version, meta_extras)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    });

    if ($flavor eq 'mysql') {
        $sth->bind_param(1, $self->_uuid_to_db($fields->{archive_uuid}), DBI::SQL_BINARY());
    }
    else {
        $sth->bind_param(1, $self->_uuid_to_db($fields->{archive_uuid}));
    }
    $sth->bind_param(2, $fields->{archive_version});
    $sth->bind_param(3, $fields->{sealed_at});
    $sth->bind_param(4, $fields->{host});
    $sth->bind_param(5, $fields->{user});
    $sth->bind_param(6, $fields->{git_sha});
    $sth->bind_param(7, $fields->{project});
    $sth->bind_param(8, $fields->{yath_version});
    $sth->bind_param(9, $extras_json);
    $sth->execute;

    return $self->_last_insert_id('archives', 'archive_id');
}

sub mark_sealed {
    my ($self, $archive_id, $when) = @_;
    croak "archive_id required" unless defined $archive_id;
    my $dbh = $self->dbh;
    $dbh->do(
        q{UPDATE archives SET sealed_at = ? WHERE archive_id = ?},
        undef, $when, $archive_id,
    );
    return;
}

# -- find-or-create rows ----------------------------------------------------
#
# ensure_project_row, ensure_test_file_row, ensure_service_row,
# ensure_job_row, and ensure_job_try_row live on
# App::Yath2::Role::DB::Backend (driven by _ensure_row above).
# ensure_run_row stays here because it generates and binds a UUID.

sub ensure_run_row {
    my ($self, $aid, $run_ord, $project_id) = @_;
    croak "archive_id required" unless defined $aid;
    croak "run_ord required"    unless defined $run_ord;
    croak "project_id required" unless defined $project_id;

    require DBI;
    my $dbh    = $self->dbh;
    my $flavor = $self->flavor;

    my ($id) = $dbh->selectrow_array(
        q{SELECT run_id FROM runs WHERE archive_id = ? AND run_ord = ?},
        undef, $aid, $run_ord,
    );
    return $id if defined $id;

    my $run_uuid = lc(gen_uuid());
    my $sth      = $dbh->prepare(q{
        INSERT INTO runs (archive_id, project_id, run_ord, run_uuid,
                          status, aborted, timed_out)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    });
    $sth->bind_param(1, $aid);
    $sth->bind_param(2, $project_id);
    $sth->bind_param(3, $run_ord);
    if ($flavor eq 'mysql') {
        $sth->bind_param(4, $self->_uuid_to_db($run_uuid), DBI::SQL_BINARY());
    }
    else {
        $sth->bind_param(4, $self->_uuid_to_db($run_uuid));
    }
    $sth->bind_param(5, 'unknown');
    $sth->bind_param(6, 0);
    $sth->bind_param(7, 0);
    $sth->execute;

    return $self->_last_insert_id('runs', 'run_id');
}

# -- artifact rows ----------------------------------------------------------

sub artifact_create {
    my ($self, $fields) = @_;
    croak "artifact_create requires a hashref" unless ref($fields) eq 'HASH';
    croak "archive_id required"                unless defined $fields->{archive_id};
    croak "artifact_kind required"             unless defined $fields->{artifact_kind};
    croak "format required"                    unless defined $fields->{format};
    croak "created_at required"                unless defined $fields->{created_at};

    require DBI;
    my $dbh    = $self->dbh;
    my $flavor = $self->flavor;

    my $artifact_uuid = lc(gen_uuid());
    my $compressed    = $fields->{compressed}    ? 1                           : 0;
    my $sealed        = exists $fields->{sealed} ? ($fields->{sealed} ? 1 : 0) : 1;
    my $payload       = $fields->{payload} // '';

    my $sth = $dbh->prepare(q{
        INSERT INTO artifacts
            (archive_id, artifact_uuid, run_id, service_id, job_try_id,
             artifact_kind, format, name, compressed, row_count,
             payload, created_at, sealed)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    });
    $sth->bind_param(1, $fields->{archive_id});
    if ($flavor eq 'mysql') {
        $sth->bind_param(2, $self->_uuid_to_db($artifact_uuid), DBI::SQL_BINARY());
    }
    else {
        $sth->bind_param(2, $self->_uuid_to_db($artifact_uuid));
    }
    $sth->bind_param(3,  $fields->{run_id});
    $sth->bind_param(4,  $fields->{service_id});
    $sth->bind_param(5,  $fields->{job_try_id});
    $sth->bind_param(6,  $fields->{artifact_kind});
    $sth->bind_param(7,  $fields->{format});
    $sth->bind_param(8,  $fields->{name});
    $sth->bind_param(9,  $compressed);
    $sth->bind_param(10, $fields->{row_count});
    $self->_bind_payload($sth, 11, $payload);
    $sth->bind_param(12, $fields->{created_at});
    $sth->bind_param(13, $sealed);
    $sth->execute;

    return $self->_last_insert_id('artifacts', 'artifact_id');
}

sub artifact_update {
    my ($self, $artifact_id, $fields) = @_;
    croak "artifact_id required"    unless defined $artifact_id;
    croak "fields hashref required" unless ref($fields) eq 'HASH';

    my @cols;
    my @binders;
    for my $k (qw/compressed row_count format created_at/) {
        next unless exists $fields->{$k};
        push @cols, "$k = ?";
        my $v = $fields->{$k};
        $v = $v ? 1 : 0 if $k eq 'compressed';
        push @binders, [$v, undef];
    }
    if (exists $fields->{payload}) {
        push @cols,    'payload = ?';
        push @binders, [$fields->{payload}, 'payload'];
    }
    return unless @cols;

    my $sql = 'UPDATE artifacts SET ' . join(', ', @cols) . ' WHERE artifact_id = ?';
    my $dbh = $self->dbh;
    my $sth = $dbh->prepare($sql);
    my $i   = 1;
    for my $b (@binders) {
        my ($val, $kind) = @$b;
        if (defined $kind && $kind eq 'payload') {
            $self->_bind_payload($sth, $i, $val);
        }
        else {
            $sth->bind_param($i, $val);
        }
        $i++;
    }
    $sth->bind_param($i, $artifact_id);
    $sth->execute;
    return;
}

# -- spec / report data layer writers --------------------------------------

# job_specs columns from share/schema/sqlite.sql §8 (job_specs table).
# Promoted typed columns are left as-is; JSON columns (features, switches,
# extras) are encoded here.
sub job_spec_create {
    my ($self, $job_id, $fields) = @_;
    croak "job_id required"         unless defined $job_id;
    croak "fields hashref required" unless ref($fields) eq 'HASH';
    croak "test_file_id required"   unless defined $fields->{test_file_id};

    my @cols = ('job_id');
    my @vals = ($job_id);

    my @scalar_cols = qw/test_file_id absolute category duration stage
                         retry retry_isolated smoke isolation non_perl
                         is_binary event_timeout post_exit_timeout
                         min_slots max_slots ch_dir/;
    for my $c (@scalar_cols) {
        next unless exists $fields->{$c};
        push @cols, $c;
        push @vals, $fields->{$c};
    }
    for my $c (qw/features switches extras/) {
        next unless exists $fields->{$c};
        push @cols, $c;
        push @vals, $self->_maybe_encode_json($fields->{$c});
    }

    my $placeholders = join(', ', ('?') x scalar(@cols));
    my $sql          = 'INSERT INTO job_specs (' . join(', ', @cols) . ") VALUES ($placeholders)";

    my $dbh = $self->dbh;
    $dbh->do($sql, undef, @vals);
    return $self->_last_insert_id('job_specs', 'job_spec_id');
}

sub service_lifetime_create {
    my ($self, $service_id, $fields) = @_;
    croak "service_id required"     unless defined $service_id;
    croak "fields hashref required" unless ref($fields) eq 'HASH';
    croak "lifetime_ord required"   unless defined $fields->{lifetime_ord};

    my @cols = ('service_id');
    my @vals = ($service_id);

    my @scalar_cols = qw/lifetime_ord status type id service_name stage_name
                         started_at ended_at exit child_wall/;
    for my $c (@scalar_cols) {
        next unless exists $fields->{$c};
        push @cols, $c;
        push @vals, $fields->{$c};
    }
    for my $c (qw/exit_decoded times child_times spec_extras state_extras/) {
        next unless exists $fields->{$c};
        push @cols, $c;
        push @vals, $self->_maybe_encode_json($fields->{$c});
    }

    # "exit" is a reserved word; quote with the same ANSI-double-quote
    # the read side uses (ANSI_QUOTES is set on MySQL/MariaDB sessions).
    my @quoted       = map { $_ eq 'exit' ? '"exit"' : $_ } @cols;
    my $placeholders = join(', ', ('?') x scalar(@cols));
    my $sql          = 'INSERT INTO service_lifetimes (' . join(', ', @quoted) . ") VALUES ($placeholders)";

    my $dbh = $self->dbh;
    $dbh->do($sql, undef, @vals);
    return $self->_last_insert_id('service_lifetimes', 'service_lifetime_id');
}

sub subtest_create {
    my ($self, $job_try_id, $fields) = @_;
    croak "job_try_id required"     unless defined $job_try_id;
    croak "fields hashref required" unless ref($fields) eq 'HASH';
    croak "name required"           unless defined $fields->{name};
    croak "ord required"            unless defined $fields->{ord};

    my $pass = $fields->{pass} ? 1 : 0;

    my @cols = qw/job_try_id name pass ord/;
    my @vals = ($job_try_id, $fields->{name}, $pass, $fields->{ord});
    for my $c (qw/count_pass count_fail/) {
        next unless exists $fields->{$c};
        push @cols, $c;
        push @vals, $fields->{$c};
    }
    my $placeholders = join(', ', ('?') x scalar(@cols));
    my $sql          = 'INSERT INTO subtests (' . join(', ', @cols) . ") VALUES ($placeholders)";

    my $dbh = $self->dbh;
    $dbh->do($sql, undef, @vals);
    return $self->_last_insert_id('subtests', 'subtest_id');
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::DB::SQL - Raw-DBI backend for L<App::Yath2::DB>.

=head1 DESCRIPTION

Single-class backend implementing L<App::Yath2::Role::DB::Backend>
through direct DBI calls. One class handles every supported flavor
(C<sqlite>, C<postgres>, C<mysql>, C<mariadb>); flavor-specific
differences (UUID bind shape, payload binding, MariaDB trigger skip,
ANSI_QUOTES session toggle) live inside individual methods rather
than in per-flavor subclasses.

End users construct via L<App::Yath2::DB>; this class is rarely
instantiated directly except by tests and by L<App::Yath2::DB> itself.

=head1 SYNOPSIS

    use App::Yath2::DB;

    # The usual entry point: App::Yath2::DB picks this backend by
    # default and wraps it.
    my $db = App::Yath2::DB->new(file => '/tmp/run.yath');

    # Direct construction (rare; tests / internals):
    use App::Yath2::DB::SQL;
    my $backend = App::Yath2::DB::SQL->new(file => '/tmp/run.yath');
    my $rows    = $backend->archive_rows;

=head1 ATTRIBUTES

=over 4

=item $val = $self->dsn

Connection DSN.

=item $val = $self->user

DBI user.

=item $val = $self->pass

DBI password.

=item $val = $self->attrs

DBI connection attributes (hashref).

=item $val = $self->file

SQLite file path (for the C<file =E<gt>> entry point).

=item $dbh = $self->dbh

Live DBI handle. Connects on demand when only one of C<file>/C<dsn>
was supplied.

=back

=head1 METHODS

The reader, writer, and bootstrap surface required by
L<App::Yath2::Role::DB::Backend>. Where the role spec covers the
contract, only backend-specific notes appear below.

=head2 Connection / introspection

=over 4

=item $self->init

Object construction hook. Validates that one of C<file>, C<dbh>, or
C<dsn> was supplied, connects, applies per-flavor session state
(C<ANSI_QUOTES> for MySQL / MariaDB), and runs C<bootstrap_schema>.

=item $flavor = $self->flavor

Detect flavor from the DSN, the DBI driver name, or the file
extension; cached on first read.

=back

Schema-bootstrap hooks (C<preprocess_schema_sql>,
C<_pg_server_compression>, C<_server_is_mariadb>,
C<_should_skip_schema_statement>) come from
L<App::Yath2::Role::DB::Backend>; consult that role for the contract.

=head2 Row primitives (multi-archive surface)

=over 4

=item $rows = $self->archive_rows

Every C<archives> row, each as a hashref with the typed columns
plus a decoded C<meta_extras>.

=item $row = $self->archive_for_uuid($uuid)

Lookup by archive uuid; C<undef> when absent.

=item $count = $self->archive_count

Number of archives in this DB.

=back

=head2 Row primitives (per-archive)

These methods take an C<$archive_id> (resolved by L<App::Yath2::DB>
from a uuid). Each returns an arrayref of row hashes.

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
=item $id = $self->service_id_for_name($aid, $name, $rid_or_run_ord)

=back

=head2 Artifact rows

=over 4

=item $rows = $self->artifact_rows_for_archive($aid, %opts)

Every artifact row for the archive, joined to the scope tables so
the row-to-path helpers in L<App::Yath2::Role::DB::Backend> can
build on-disk-relative paths. C<with_payload =E<gt> 1> includes the
C<payload> blob.

=item $row = $self->artifact_row_for_scope($aid, $scope_kind, $scope_id, $artifact_kind, $name)

Lookup a single artifact row by its scope tuple.

=item $bytes = $self->artifact_payload($artifact_id)

Read just the payload bytes for one artifact.

=back

=head2 Write primitives

The data layer in L<App::Yath2::DB> calls these to mint rows during
C<insert> and C<save_artifact>. Each returns the new row's primary key
(or, for the C<ensure_*> helpers, the existing row's id when one was
already present).

=over 4

=item $aid = $self->archive_create($fields)

Insert a new C<archives> row.

=item $self->mark_sealed($aid)

Update C<sealed_at> on an archive row to mark it sealed.

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

Pure inserts / updates. The data layer is responsible for shaping
C<$fields> appropriately for each table.

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
