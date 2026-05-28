package Test2::Harness2;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use DBI;
use POSIX      ();
use File::Spec ();
use Scalar::Util qw/blessed/;
use Test2::Harness2::Util qw/now_dt share_dir/;
use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Collector;
use Test2::Harness2::DB::Flavor;

# Import the QuickORM DSL helpers. 'connect' is renamed to 'qorm_connect' so
# it does not collide with the Object::HashBase 'connect' slot accessor below.
use DBIx::QuickORM
    rename => {connect => 'qorm_connect'},
    only   => [qw/db dialect connect db_name/];

use Test2::Harness2::Schema;    # installs qorm() into this package

use Object::HashBase qw{
    <db_path
    <credentials
    <connect
    <ephemeral
    <flavor
    <dsn
    <username
    <password
    <flavor_obj
    +quickdb
    +orm
    +connection
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2 - Top-level harness object: DB bootstrap and connection factory.

=head1 DESCRIPTION

C<Test2::Harness2> is the entry-point object for the harness database. It
bootstraps a database from the bundled DDL, then provides a
L<DBIx::QuickORM::Connection> through which the rest of the harness accesses
the schema.

At minimum one of C<db_path>, C<dsn>, C<credentials>/C<connect>, or
C<ephemeral> must be supplied. The default backend is SQLite (via
C<db_path>). A C<dsn>/C<flavor>/C<username>/C<password> set enables other
database engines. Pass C<ephemeral =E<gt> 1> to provision an ephemeral SQLite
database via L<DBIx::QuickDB>, or C<ephemeral =E<gt> 'postgresql'> (or any
other supported flavor name) to spin up a full server of that flavor.

=head1 SYNOPSIS

    use Test2::Harness2;

    my $h = Test2::Harness2->new(db_path => '/path/to/harness.sqlite');
    $h->initialize;          # create the file and load the DDL once

    my $con = $h->connection;
    my $run = $con->handle('run');

=head1 ATTRIBUTES

=over 4

=item db_path

Path to the SQLite database file. Required unless C<credentials>/C<connect>
is supplied.

=item credentials

A coderef or object with a C<connect> method that returns a fresh DBI handle.
Aliases with C<connect>; both names refer to the same underlying value.

=item connect

Alias for C<credentials>. Whichever name is passed, both accessors are set.

=item ephemeral

Enable ephemeral database provisioning via L<DBIx::QuickDB>. Pass C<1> to
get an ephemeral SQLite database in a temporary directory. Pass a flavor name
(e.g. C<'postgresql'>) to spin up a server of that flavor. The provisioned
database is torn down when the harness object is garbage-collected.

=item flavor

Symbolic name of the database engine: C<sqlite>, C<postgresql>, C<mysql>,
C<mariadb>, or C<percona>. When set, it overrides DSN inference.

=item dsn

A DBI connection string (e.g. C<dbi:Pg:dbname=yath>). Used together with
C<username> and C<password> when connecting to a non-SQLite database.

=item username

Database username for DSN-based connections.

=item password

Database password for DSN-based connections.

=back

=cut

sub init ($self) {
    $self->{+CONNECT}     //= $self->{+CREDENTIALS};
    $self->{+CREDENTIALS} //= $self->{+CONNECT};

    croak "one of db_path, dsn, credentials/connect, or ephemeral is required"
        unless $self->{+DB_PATH}
        || $self->{+DSN}
        || $self->{+CREDENTIALS}
        || $self->{+EPHEMERAL};

    $self->{+FLAVOR_OBJ} = $self->_resolve_flavor;

    return;
}

=pod

=head1 PUBLIC METHODS

=over 4

=item $db = $h->quickdb

Return (building and caching on first call) the ephemeral L<DBIx::QuickDB>
instance for this harness. Returns C<undef> when C<ephemeral> was not set.
The instance is cached for the lifetime of the harness object; QuickDB tears
down its server when the object is garbage-collected, so the harness object
must stay alive as long as the database is in use.

C<ephemeral =E<gt> 1> provisions a SQLite database in a temporary directory.
C<ephemeral =E<gt> 'postgresql'> (or any other supported flavor name) spins up
a server of that flavor. In both cases, C<initialize> applies the DDL and
C<connection> connects through the live QuickDB handle.

=cut

sub quickdb ($self) {
    return $self->{+QUICKDB} if $self->{+QUICKDB};
    return undef unless $self->{+EPHEMERAL};

    require DBIx::QuickDB;
    my $flavor = $self->{+FLAVOR_OBJ};
    return $self->{+QUICKDB} = DBIx::QuickDB->build_db(
        harness => {driver => $flavor->quickdb_driver},
    );
}

=item $h->initialize

Apply the DDL for the resolved flavor to a fresh database. For SQLite,
creates the file at C<db_path> and applies C<share/schema/sqlite.sql>. For
ephemeral databases, applies the DDL to the QuickDB-provisioned instance. Safe
to call only once; the DDL uses C<CREATE TABLE> without C<IF NOT EXISTS>.
Requires a resolved flavor (MySQL-family connections must supply an explicit
C<flavor> parameter).

=cut

sub initialize ($self) {
    my $flavor = $self->{+FLAVOR_OBJ}
        or croak "initialize requires a resolved flavor (mysql-family needs an explicit flavor)";

    my $dbh = $self->connect_cb->();

    my $sql_file = $flavor->ddl_path;
    my $sql      = do {
        open my $fh, '<', $sql_file or croak "open $sql_file: $!";
        local $/;
        <$fh>;
    };
    $dbh->do($_) for grep { /\S/ } split /;\s*\n/, $sql;
    $dbh->disconnect;

    return;
}

=pod

=item $cb = $h->connect_cb

Return a coderef that produces a fresh DBI handle on each call. When
C<ephemeral> is set, the coderef opens a connection through the cached
L<DBIx::QuickDB> instance. When C<credentials> was provided, the coderef
delegates to it (either invoking it directly if it is a coderef, or calling
C<connect> on the object). When only C<db_path> is set, builds a SQLite connect
coderef with WAL journal mode and a generous busy timeout. When C<dsn> is set,
builds a connect coderef using the DSN, C<username>, and C<password>.

=cut

sub connect_cb ($self) {
    if (my $db = $self->quickdb) {
        my $flavor = $self->{+FLAVOR_OBJ};
        return sub {
            my $dbh = $db->connect('quickdb', AutoCommit => 1, RaiseError => 1, PrintError => 0);
            $flavor->post_connect($dbh);
            return $dbh;
        };
    }

    if (my $creds = $self->{+CREDENTIALS}) {
        return $creds if ref($creds) eq 'CODE';
        return sub { $creds->connect }
            if blessed($creds) && $creds->can('connect');
        croak "credentials must be a coderef or a Credentials consumer";
    }

    if (my $dsn = $self->{+DSN}) {
        my $user   = $self->{+USERNAME};
        my $pass   = $self->{+PASSWORD};
        my $flavor = $self->{+FLAVOR_OBJ};
        return sub {
            my $dbh = DBI->connect(
                $dsn, $user, $pass,
                {RaiseError => 1, PrintError => 0, AutoCommit => 1},
            );
            $flavor->post_connect($dbh) if $flavor;
            return $dbh;
        };
    }

    my $path   = $self->{+DB_PATH};
    my $flavor = $self->{+FLAVOR_OBJ};
    return sub {
        my $dbh = DBI->connect(
            "dbi:SQLite:dbname=$path", '', '',
            {RaiseError => 1, PrintError => 0, AutoCommit => 1},
        );
        $flavor->post_connect($dbh);
        return $dbh;
    };
}

=pod

=item $spec = $h->connect_spec

Return a plain hashref of constructor arguments sufficient to rebuild an
equivalent C<Test2::Harness2> object in another process. For SQLite, returns
C<< { flavor =E<gt> 'sqlite', db_path =E<gt> $path } >>. For ephemeral
databases, returns C<flavor>, C<dsn>, C<username>, and C<password> from the
live QuickDB instance so forked children can reconnect over the wire — the
QuickDB object itself is never carried across a fork. For DSN-based
connections, returns C<flavor>, C<dsn>, C<username>, and C<password>.

=cut

sub connect_spec ($self) {
    croak "connect_spec is not supported for credentials/connect-based harnesses (the handle supplier cannot cross a fork)"
        if $self->{+CREDENTIALS};

    my $flavor = $self->{+FLAVOR_OBJ} // $self->_flavor_obj_resolved($self->connect_cb);

    return {flavor => 'sqlite', db_path => $self->{+DB_PATH}}
        if $self->{+DB_PATH};

    if (my $db = $self->quickdb) {
        return {
            flavor   => $flavor->name,
            dsn      => $db->connect_string('quickdb'),
            username => $db->username,
            password => $db->password,
        };
    }

    return {
        flavor   => $flavor->name,
        dsn      => $self->{+DSN},
        username => $self->{+USERNAME},
        password => $self->{+PASSWORD},
    };
}

=pod

=item $con = $h->connection

Return the L<DBIx::QuickORM::Connection> for this harness instance, building
and caching it on first call. The connection triggers a lazy C<autofill>
introspection of the live database; the DDL must already be applied
(via C<initialize>) before this is called.

=item $run = $h->queue_run(%params)

Insert a run row and one job row per test file in a single transaction,
returning the new run row. Required params: C<runner_uuid>, C<project_id>,
C<files> (arrayref of test-file paths). Optional: C<account_id>, C<version_id>.
Each C<(project_id, test_file)> pair is looked up in C<test_file> and inserted
if absent, so repeated paths within a project reuse the same row
(single-writer; not safe against a concurrent insert of the same pair).
Call C<< $run->refresh >> to observe later updates (e.g. the runner stamping
C<stopped> / C<passed>).

=item $h->finalize_run($run_uuid)

Remove the on-disk event files for every artifact belonging to the run and
null their C<local_path>. Call this after the collector has finished
capturing the run's data.

=item $service = $h->start_runner(%params)

Insert the runner and service rows (sharing one UUID), then fork a process
that becomes a collector wrapping the runner service loop. The collector owns
its own collector row and a runner-level events artifact; its forked child
runs the L<Test2::Harness2::Runner> service. Returns the new service row;
update its C<mode> column (C<run> / C<stop> / C<kill>) to control the running
service. C<stop> drains outstanding work then exits, C<kill> terminates
running tests then exits. Optional param: C<workdir> (passed through to the
runner for per-test event files).

=back

=head1 PRIVATE METHODS

=over 4

=item $flavor = $h->_resolve_flavor

Determine the flavor for this harness instance. Explicit C<flavor> wins, then
unambiguous DSN inference, then C<db_path> (sqlite), then ephemeral name.
MySQL-family DSNs return C<undef> here and are probed at connection time.

=cut

sub _resolve_flavor ($self) {
    my $F = 'Test2::Harness2::DB::Flavor';

    return $F->by_name($self->{+FLAVOR}) if $self->{+FLAVOR};

    if (my $dsn = $self->{+DSN}) {
        my $f = $F->infer_from_dsn($dsn);
        return $f if $f;
        return;
    }

    return $F->by_name('sqlite') if $self->{+DB_PATH};

    if (my $eph = $self->{+EPHEMERAL}) {
        return $F->by_name($eph) if $eph ne '1' && $eph ne '';
        return $F->by_name('sqlite');
    }

    return $F->by_name('sqlite');
}

=pod

=item $flavor = $h->_flavor_obj_resolved($cb)

Return the resolved flavor, probing a live handle for MySQL-family DSNs that
could not be told apart from the DSN string alone. Croaks if the probe is
inconclusive. Caches the result in C<flavor_obj> for subsequent calls.

=cut

sub _flavor_obj_resolved ($self, $cb) {
    return $self->{+FLAVOR_OBJ} if $self->{+FLAVOR_OBJ};

    my $dbh    = $cb->();
    my $flavor = Test2::Harness2::DB::Flavor->detect_from_dbh($dbh);
    $dbh->disconnect;

    croak "could not determine MySQL-family flavor from the server; pass an explicit flavor (mysql, mariadb, or percona)"
        unless $flavor;

    return $self->{+FLAVOR_OBJ} = $flavor;
}

=pod

=item $name = $h->_orm_db_name

Return the database/catalog name that the QuickORM dialect uses during autofill
to filter C<information_schema> rows. For SQLite (C<db_path>), this is the file
path. For ephemeral QuickDB instances, it is C<'quickdb'> (the name QuickDB
always provisions). For DSN-based harnesses — including forked children rebuilt
from a C<connect_spec> — it is the database name embedded in the DSN
(C<dbname=...> or C<database=...>). Falls back to C<':memory:'> when none of
the above apply (e.g. a plain credentials harness with no DSN).

This is the fix for the DSN propagation bug: without it, a child rebuilt from
C<connect_spec> for a non-sqlite flavor would get C<':memory:'> as its ORM
C<db_name>, which matches nothing in C<information_schema>, so autofill would
find no tables and C<handle('run')> would fail.

=back

=cut

# The ORM db_name is the database/catalog name the dialect introspects against
# during autofill. For a DSN-based harness (e.g. a forked child rebuilt from
# connect_spec) it must be the database named in the DSN, not ':memory:' --
# PostgreSQL/MySQL autofill filter information_schema by this name.
sub _orm_db_name ($self) {
    return $self->{+DB_PATH} if defined $self->{+DB_PATH};

    if (my $dsn = $self->{+DSN}) {
        return $1 if $dsn =~ /\b(?:dbname|database)=([^;]+)/i;
    }

    return 'quickdb' if $self->{+EPHEMERAL};

    return ':memory:';
}

sub connection ($self) {
    return $self->{+CONNECTION}
        if $self->{+CONNECTION} && $self->{+CONNECTION}->pid == $$;

    my $orm  = $self->{+ORM} //= qorm(orm => 'harness');
    my $cb   = $self->connect_cb;
    my $path = $self->_orm_db_name;

    # The ORM is a process-global singleton; its db may already be set by a
    # connection made earlier in this process (or before a fork). Setting it
    # twice croaks, so only attach when it has not been attached yet.
    # This means the first connection() call in a process fixes the dialect and
    # db_name for that process's lifetime. The harness topology is one flavor
    # per process (each forked child reconnects in its own process via
    # connect_spec), so this is sufficient; mixing two different flavors in a
    # single process is not supported.
    my $flavor       = $self->_flavor_obj_resolved($cb);
    my $dialect_name = $flavor->dialect;
    my $has_db       = eval { $orm->db; 1 };
    $orm->db(db(sub {
        db_name $path;
        dialect $dialect_name;
        qorm_connect($cb);
    })) unless $has_db;

    # A DBI handle must not be shared across a fork. When the ORM's cached
    # connection belongs to another process (we forked since it was built),
    # reconnect to get a fresh handle bound to this process.
    my $con = $orm->connection;
    $con = $orm->reconnect if $con->pid != $$;

    return $self->{+CONNECTION} = $con;
}

sub queue_run ($self, %params) {
    my $files = $params{files} or croak "queue_run requires 'files'";
    croak "queue_run requires 'runner_uuid'" unless $params{runner_uuid};
    croak "queue_run requires 'project_id'"  unless $params{project_id};

    my $con        = $self->connection;
    my $run_uuid   = gen_uuid();
    my $project_id = $params{project_id};
    my $run;

    $con->txn(sub {
        $run = $con->handle('run')->insert({
            run_uuid    => $run_uuid,
            runner_uuid => $params{runner_uuid},
            account_id  => $params{account_id},
            project_id  => $project_id,
            version_id  => $params{version_id},
            started     => now_dt(),
        });

        for my $file (@$files) {
            my $tf = $con->find_or_insert(test_file => {project_id => $project_id, test_file => $file});

            $con->handle('job')->insert({
                job_uuid     => gen_uuid(),
                run_uuid     => $run_uuid,
                runner_uuid  => $params{runner_uuid},
                test_file_id => $tf->field('test_file_id'),
            });
        }
    });

    return $run;
}

sub finalize_run ($self, $run_uuid) {
    my $con = $self->connection;

    # Fetch and update inside one transaction: QuickORM rejects updates to
    # rows that were fetched outside the current transaction stack.
    $con->txn(sub {
        my @artifacts = $con->handle('artifact', where => {run_uuid => $run_uuid})->all;
        for my $art (@artifacts) {
            my $path = $art->field('local_path') or next;
            warn "finalize_run: unlink $path failed: $!\n"
                if -e $path && !unlink($path);
            $art->update({local_path => undef});
        }
    });

    return;
}

sub start_runner ($self, %params) {
    # Required lazily to avoid a use-time cycle: Runner uses Test2::Harness2.
    require Test2::Harness2::Runner;

    my $con         = $self->connection;
    my $runner_uuid = gen_uuid();
    my $service;

    $con->txn(sub {
        $con->handle('runner')->insert({runner_uuid => $runner_uuid});
        $service = $con->handle('service')->insert({
            service_uuid => $runner_uuid,
            runner_uuid  => $runner_uuid,
            name         => 'runner',
            mode         => 'run',
            started      => now_dt(),
        });
    });

    my $spec    = $self->connect_spec;
    my $workdir = $params{workdir};

    my $pid = fork // die "fork: $!";
    if ($pid == 0) {
        my $exit = 255;
        my $ok   = eval {
            # Collector-parent process: owns the collector row + runner artifact.
            my $pcon   = Test2::Harness2->new(%$spec)->connection;
            my $events = File::Spec->catfile(File::Spec->tmpdir, "yath-runner-$runner_uuid.jsonl.zst");

            my $crow = $pcon->handle('collector')->insert({
                service_uuid => $runner_uuid,
                runner_uuid  => $runner_uuid,
                mode         => 'run',
            });
            my $arow = $pcon->handle('artifact')->insert({
                artifact_uuid => gen_uuid(),
                service_uuid  => $runner_uuid,
                name          => 'events',
                type          => 'jsonl.zst',
                local_path    => $events,
            });
            my $artifact_uuid = $arow->field('artifact_uuid');

            $exit = Test2::Harness2::Collector->start(
                is_test       => 0,
                events_file   => $events,
                collector_row => $crow,
                artifact_row  => $arow,
                run_sub       => sub ($guard) {
                    Test2::Harness2::Runner->new(
                        connect_spec => $spec,
                        runner_uuid  => $runner_uuid,
                        ($workdir ? (workdir => $workdir) : ()),
                    )->run;
                },
            );

            # Events data is now in the artifact blob; remove the on-disk file.
            unlink($events) if -e $events;
            my $finished = $pcon->handle('artifact')->by_id($artifact_uuid);
            $finished->update({local_path => undef}) if $finished;

            1;
        };
        warn "runner collector child failed: $@\n" unless $ok;
        POSIX::_exit($ok ? ($exit ? $exit : 0) : 255);
    }

    return $service;
}

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
