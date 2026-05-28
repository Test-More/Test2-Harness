use v5.38;
use Test2::V0;
use DBI;
use Test2::Harness2::Util qw/share_dir/;

my $sql_file = share_dir() . '/schema/sqlite.sql';
ok(-f $sql_file, "sqlite.sql exists at $sql_file");

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1, PrintError => 0 });
$dbh->do('PRAGMA foreign_keys = ON');

my $sql = do { open my $fh, '<', $sql_file or die "open $sql_file: $!"; local $/; <$fh> };
# Statements are separated by ";" on its own followed by newline; split and run each.
for my $stmt (grep { /\S/ } split /;\s*\n/, $sql) {
    ok(lives { $dbh->do($stmt) }, "ran DDL statement") or diag($@), diag($stmt);
}

my %have = map { $_->[0] => 1 } @{ $dbh->selectall_arrayref("SELECT name FROM sqlite_master WHERE type='table'") };
my @want = qw/collector socket account project version test_file runner service run job try subtest artifact/;
ok($have{$_}, "table $_ created") for @want;

# Smoke a couple of inserts honoring fk + uniqueness.
ok(lives { $dbh->do("INSERT INTO project (name) VALUES ('p1')") }, "insert project");
ok(dies  { $dbh->do("INSERT INTO project (name) VALUES ('p1')") }, "duplicate project name rejected");

done_testing;
