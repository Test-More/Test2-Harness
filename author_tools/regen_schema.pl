use strict;
use warnings;

use DBIx::QuickDB;

my $db = DBIx::QuickDB->build_db(harness_ui => {driver => 'PostgreSQL'});
{
    my $dbh = $db->connect('quickdb', AutoCommit => 1, RaiseError => 1);
    $dbh->do('CREATE DATABASE harness_ui') or die "Could not create db " . $dbh->errstr;
    $db->load_sql(harness_ui => 'schema/postgresql.sql');
    $db->load_sql(harness_ui => 'schema/postgresql_demo.sql');
}

print "XXX: " . $db->connect_string('harness_ui') . "\n";

system(
    'dbicdump',
    '-o' => 'dump_directory=./lib',
    '-o' => 'components=["InflateColumn::DateTime", "InflateColumn::Serializer", "InflateColumn::Serializer::JSON", "Tree::AdjacencyList"]',
    '-o' => 'debug=1',
    'Test2::Harness::UI::Schema',
    $db->connect_string('harness_ui'),
    '',
    ''
) and die "Error";
