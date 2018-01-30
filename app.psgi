use strict;
use warnings;
use Plack::Builder;

use Test2::Harness::UI::Schema;
use Test2::Harness::UI::Controller::Feed;

use DBIx::QuickDB;

my $db = DBIx::QuickDB->build_db(harness_ui => {driver => 'PostgreSQL'});
{
    my $dbh = $db->connect('quickdb', AutoCommit => 1, RaiseError => 1);
    $dbh->do('CREATE DATABASE harness_ui;') or die "Could not create db " . $dbh->errstr;
    $db->load_sql(harness_ui => 'schema/postgresql.sql');
}

my $schema = Test2::Harness::UI::Schema->connect({dbh_maker => sub { $db->connect('harness_ui', AutoCommit => 1, RaiseError => 1) }});

builder {
    mount "/feed" => Test2::Harness::UI::Controller::Feed->new(schema => $schema)->to_app;

    mount "/" => sub {
        my $env = shift;

        return [ '200', ['Content-Type' => 'text/html'], ["<html>Hello World</html>"] ]
    };
};
