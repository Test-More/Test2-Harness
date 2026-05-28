use Test2::V0;
use Test2::Harness2;

BEGIN {
    eval { require DBIx::QuickDB; 1 } or skip_all "DBIx::QuickDB not available";
    eval { require DBD::Pg;       1 } or skip_all "DBD::Pg not available";
    require DBIx::QuickDB::Driver::PostgreSQL;
    my ($ok, $why) = DBIx::QuickDB::Driver::PostgreSQL->viable({bootstrap => 1, autostart => 1});
    skip_all "PostgreSQL not provisionable: $why" unless $ok;
}

# $h owns the ephemeral QuickDB server and applies the DDL via a raw DBI handle
# (not via the process-global ORM singleton). Keep $h in scope so the server
# stays alive for the duration of the test.
my $h = Test2::Harness2->new(ephemeral => 'postgresql');
$h->initialize;

my $spec = $h->connect_spec;
is($spec->{flavor}, 'postgresql', 'connect_spec carries flavor');
like($spec->{dsn}, qr/^dbi:Pg:/i, 'connect_spec carries pg dsn');
ok(!exists $spec->{db_path}, 'pg spec has no db_path (dsn only)');

# Build and connect the child from the GENUINE spec (dsn only, no db_path),
# BEFORE any $h->connection call, so the child is the first to attach the ORM
# singleton -- this genuinely exercises connect_spec propagation end to end.
my $child = Test2::Harness2->new(%$spec);
is($child->flavor_obj->name, 'postgresql', 'child resolves postgresql from spec');
my $ccon = $child->connection;
ok($ccon->handle('run'), 'child connects via spec dsn and sees schema');

done_testing;
