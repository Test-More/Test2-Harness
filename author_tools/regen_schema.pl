use strict;
use warnings;

use DBIx::QuickDB;

my $db = DBIx::QuickDB->build_db(harness_ui => {driver => 'PostgreSQL'});
{
    my $dbh = $db->connect('quickdb', AutoCommit => 1, RaiseError => 1);
    $dbh->do('CREATE DATABASE harness_ui') or die "Could not create db " . $dbh->errstr;
    $db->load_sql(harness_ui => 'share/schema/postgresql.sql');
}

system(
    'dbicdump',
    '-o' => 'dump_directory=./lib',
    '-o' => 'components=["InflateColumn::DateTime", "InflateColumn::Serializer", "InflateColumn::Serializer::JSON", "Tree::AdjacencyList", "UUIDColumns"]',
    '-o' => 'debug=1',
    '-o' => 'skip_load_external=1',
    'Test2::Harness::UI::Schema',
    $db->connect_string('harness_ui'),
    '',
    ''
) and die "Error";
