package Test2::Harness2;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use DBI;
use POSIX      ();
use File::Spec ();
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;
use Test2::Harness2::Util qw/share_dir/;
use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Collector;

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
    +orm
    +connection
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2 - Top-level harness object: DB bootstrap and connection factory.

=head1 DESCRIPTION

C<Test2::Harness2> is the entry-point object for the harness database. It
bootstraps a SQLite database from the bundled DDL, then provides a
L<DBIx::QuickORM::Connection> through which the rest of the harness accesses
the schema.

Either C<db_path> (for SQLite) or C<credentials> / C<connect> (for a
pre-existing database handle supplier) must be supplied. Ephemeral databases
are not yet supported.

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

Reserved for future use. Setting this flag currently croaks.

=back

=cut

sub init ($self) {
    $self->{+CONNECT}     //= $self->{+CREDENTIALS};
    $self->{+CREDENTIALS} //= $self->{+CONNECT};

    croak "either db_path, credentials/connect, or ephemeral is required"
        unless $self->{+DB_PATH} || $self->{+CREDENTIALS} || $self->{+EPHEMERAL};

    croak "ephemeral databases are not supported yet"
        if $self->{+EPHEMERAL};

    return;
}

=pod

=head1 PUBLIC METHODS

=over 4

=item $h->initialize

Create the SQLite file at C<db_path> and apply the DDL from
C<share/schema/sqlite.sql>. Safe to call only once on a fresh path; the DDL
uses C<CREATE TABLE> without C<IF NOT EXISTS>, so calling it twice against the
same file will error. Does nothing with custom credentials — callers that
supply their own database manage their own schema.

=item $cb = $h->connect_cb

Return a coderef that produces a fresh DBI handle on each call. When
C<credentials> was provided, the coderef delegates to it (either invoking it
directly if it is a coderef, or calling C<connect> on the object). When only
C<db_path> is set, builds a SQLite connect coderef with WAL journal mode and a
generous busy timeout.

=item $con = $h->connection

Return the L<DBIx::QuickORM::Connection> for this harness instance, building
and caching it on first call. The connection triggers a lazy C<autofill>
introspection of the live database; the DDL must already be applied
(via C<initialize>) before this is called.

=item $run_uuid = $h->queue_run(%params)

Insert a run row and one job row per test file in a single transaction,
returning the new run UUID. Required params: C<runner_uuid>, C<files>
(arrayref of test-file paths). Optional: C<user_id>, C<project_id>,
C<version_id>. Each path is looked up in C<test_file> and inserted if absent,
so repeated paths reuse the same row (single-writer; not safe against a
concurrent insert of the same path).

=item $h->finalize_run($run_uuid)

Remove the on-disk event files for every artifact belonging to the run and
null their C<local_path>. Call this after the collector has finished
capturing the run's data.

=item $runner_uuid = $h->start_runner(%params)

Insert the runner and service rows (sharing one UUID), then fork a process
that becomes a collector wrapping the runner service loop. The collector owns
its own collector row and a runner-level events artifact; its forked child
runs the L<Test2::Harness2::Runner> service. Returns the new runner UUID.
Optional param: C<workdir> (passed through to the runner for per-test event
files).

=item $h->set_runner_mode($runner_uuid, $mode)

Update the runner's service-row C<mode> (C<run> / C<stop> / C<kill>). The
runner observes this each tick: C<stop> drains outstanding work then exits,
C<kill> terminates running tests then exits.

=back

=cut

sub initialize ($self) {
    my $path = $self->{+DB_PATH}
        or croak "initialize requires db_path (custom credentials manage their own schema)";

    my $dbh = DBI->connect(
        "dbi:SQLite:dbname=$path", '', '',
        {RaiseError => 1, PrintError => 0, AutoCommit => 1},
    );
    $dbh->do('PRAGMA foreign_keys = ON');

    my $sql_file = share_dir() . '/schema/sqlite.sql';
    my $sql      = do {
        open my $fh, '<', $sql_file or croak "open $sql_file: $!";
        local $/;
        <$fh>;
    };
    $dbh->do($_) for grep { /\S/ } split /;\s*\n/, $sql;
    $dbh->disconnect;

    return;
}

sub connect_cb ($self) {
    if (my $creds = $self->{+CREDENTIALS}) {
        return $creds if ref($creds) eq 'CODE';
        return sub { $creds->connect }
            if blessed($creds) && $creds->can('connect');
        croak "credentials must be a coderef or a Credentials consumer";
    }

    my $path = $self->{+DB_PATH};
    return sub {
        my $dbh = DBI->connect(
            "dbi:SQLite:dbname=$path", '', '',
            {RaiseError => 1, PrintError => 0, AutoCommit => 1},
        );
        $dbh->do('PRAGMA foreign_keys = ON');
        $dbh->do('PRAGMA journal_mode = WAL');
        $dbh->do('PRAGMA busy_timeout = 60000');
        return $dbh;
    };
}

sub connection ($self) {
    return $self->{+CONNECTION}
        if $self->{+CONNECTION} && $self->{+CONNECTION}->pid == $$;

    my $orm  = $self->{+ORM} //= qorm(orm => 'harness');
    my $cb   = $self->connect_cb;
    my $path = $self->{+DB_PATH} // ':memory:';

    # The ORM is a process-global singleton; its db may already be set by a
    # connection made earlier in this process (or before a fork). Setting it
    # twice croaks, so only attach when it has not been attached yet.
    my $has_db = eval { $orm->db; 1 };
    $orm->db(db(sub {
        db_name $path;
        dialect 'SQLite';
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

    my $con      = $self->connection;
    my $run_uuid = gen_uuid();

    $con->txn(sub {
        $con->handle('run')->insert({
            run_uuid    => $run_uuid,
            runner_uuid => $params{runner_uuid},
            user_id     => $params{user_id},
            project_id  => $params{project_id},
            version_id  => $params{version_id},
            started     => time,
        });

        for my $file (@$files) {
            my $tf = $con->handle('test_file', where => {test_file => $file})->one // $con->handle('test_file')->insert({test_file => $file});

            $con->handle('job')->insert({
                job_uuid     => gen_uuid(),
                run_uuid     => $run_uuid,
                runner_uuid  => $params{runner_uuid},
                test_file_id => $tf->field('test_file_id'),
            });
        }
    });

    return $run_uuid;
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

    $con->txn(sub {
        $con->handle('runner')->insert({runner_uuid => $runner_uuid});
        $con->handle('service')->insert({
            service_uuid => $runner_uuid,
            runner_uuid  => $runner_uuid,
            name         => 'runner',
            mode         => 'run',
            started      => time,
        });
    });

    my $db_path = $self->{+DB_PATH};
    my $workdir = $params{workdir};

    my $pid = fork // die "fork: $!";
    if ($pid == 0) {
        my $exit = 255;
        my $ok   = eval {
            # Collector-parent process: owns the collector row + runner artifact.
            my $pcon   = Test2::Harness2->new(db_path => $db_path)->connection;
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
                        db_path     => $db_path,
                        runner_uuid => $runner_uuid,
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

    return $runner_uuid;
}

sub set_runner_mode ($self, $runner_uuid, $mode) {
    my $svc = $self->connection->handle('service')->by_id($runner_uuid)
        or croak "no service row for runner $runner_uuid";
    $svc->update({mode => $mode});
    return;
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
