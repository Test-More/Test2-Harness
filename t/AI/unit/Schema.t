use Test2::V0;
use v5.38;

use DBI;
use Test2::Harness2::Schema;
use DBIx::QuickORM only => [qw/db dialect connect db_name/];

# use Test2::Harness2::Schema installs a qorm() accessor into this package
# (DBIx::QuickORM's default export name). qorm(orm => $name) fetches the ORM.
my $orm = qorm(orm => 'harness');
isa_ok($orm, ['DBIx::QuickORM::ORM'], "qorm(orm => 'harness') returns an ORM object");

# The schema bakes in no database -- fetching the db before one is attached
# must croak.
like(
    dies { $orm->db },
    qr/'db' has not been set/,
    "no database baked into the schema",
);

# Attach a connect callback over a fresh empty SQLite database and confirm
# the connection (and therefore lazy autofill introspection) succeeds without
# error against an empty schema.
$orm->db(db(sub {
    db_name ':memory:';
    dialect 'SQLite';
    connect(sub { DBI->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1, PrintError => 0 }) });
}));

my $con;
ok(lives { $con = $orm->connection }, "connection over an empty SQLite db succeeds")
    or note($@);
isa_ok($con, ['DBIx::QuickORM::Connection'], "got a Connection back");

done_testing;
