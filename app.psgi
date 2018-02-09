use strict;
use warnings;
use Plack::Builder;

BEGIN {$ENV{T2_HARNESS_UI_ENV} = 'dev'}

use Test2::Harness::UI;
use Test2::Harness::UI::Config;
use DBIx::QuickDB;
use File::Temp qw/tempdir/;

my $db = DBIx::QuickDB->build_db(harness_ui => {driver => 'PostgreSQL'});
{
    my $dbh = $db->connect('quickdb', AutoCommit => 1, RaiseError => 1);
    $dbh->do('CREATE DATABASE harness_ui') or die "Could not create db " . $dbh->errstr;
    $db->load_sql(harness_ui => 'schema/postgresql.sql');
    $db->load_sql(harness_ui => 'schema/postgresql_demo.sql');
}

my $uploads = tempdir("T2_HARNESS_UI_UPLOADS-XXXXXXXX", CLEANUP => 1, TMPDIR => 1);

my $dsn = $db->connect_string('harness_ui');
print "Upload Dir: $uploads\n";
print "DBI_DSN: $dsn\n";
print "Both: '$dsn' '$uploads'\n";

my $config = Test2::Harness::UI::Config->new(
    dbi_dsn     => $dsn,
    dbi_user    => '',
    dbi_pass    => '',
    upload_dir  => $uploads,
#    single_user => 1,
);

Test2::Harness::UI->new(config => $config)->to_app;
