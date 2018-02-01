use strict;
use warnings;
use Plack::Builder;

BEGIN {$ENV{T2_HARNESS_UI_ENV} = 'dev'}

use Test2::Harness::UI;
use Test2::Harness::UI::Schema;
use DBIx::QuickDB;

my $db = DBIx::QuickDB->build_db(harness_ui => {driver => 'PostgreSQL'});
{
    my $dbh = $db->connect('quickdb', AutoCommit => 1, RaiseError => 1);
    $dbh->do('CREATE DATABASE harness_ui') or die "Could not create db " . $dbh->errstr;
    $db->load_sql(harness_ui => 'schema/postgresql.sql');
    $db->load_sql(harness_ui => 'schema/postgresql_demo.sql');
}

my $schema = Test2::Harness::UI::Schema->connect({dbh_maker => sub { $db->connect('harness_ui', AutoCommit => 1, RaiseError => 1) }});

Test2::Harness::UI->new(schema => $schema)->to_app;
