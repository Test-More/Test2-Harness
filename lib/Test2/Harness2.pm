package Test2::Harness2;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use DBI;
use Scalar::Util qw/blessed/;
use Test2::Harness2::Util qw/share_dir/;

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
    -orm
    -connection
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
    return $self->{+CONNECTION} if $self->{+CONNECTION};

    my $orm  = $self->{+ORM} //= qorm(orm => 'harness');
    my $cb   = $self->connect_cb;
    my $path = $self->{+DB_PATH} // ':memory:';

    $orm->db(db(sub {
        db_name $path;
        dialect 'SQLite';
        qorm_connect($cb);
    }));

    return $self->{+CONNECTION} = $orm->connection;
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
