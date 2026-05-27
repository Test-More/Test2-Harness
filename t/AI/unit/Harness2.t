use v5.38;
use Test2::V0;
use File::Temp qw/tempdir/;
use Test2::Harness2;

my $dir  = tempdir(CLEANUP => 1);
my $path = "$dir/harness.sqlite";

my $h = Test2::Harness2->new(db_path => $path);
isa_ok($h, ['Test2::Harness2'], "constructed harness");

ok(lives { $h->initialize }, "initialize creates the sqlite file + loads DDL") or diag($@);
ok(-s $path, "sqlite file exists and is non-empty");

my $con = $h->connection;
isa_ok($con, ['DBIx::QuickORM::Connection'], "got a connection");

# The schema autofilled: the run table handle is usable.
ok(lives { $con->handle('run') }, "run table handle available");

done_testing;
