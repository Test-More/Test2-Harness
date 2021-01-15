package Test2::Harness::DB::Postgresql;
use strict;
use warnings;

use Test2::API qw/context/;
use Test2::Tools::QuickDB;
use Test2::Harness::UI::Schema::PostgreSQL;
use Test2::Harness::UI::Schema;

sub new {
    my $class = shift;

    my $ctx = context();

    my $db = get_db_or_skipall({driver => 'PostgreSQL', load_sql => [quickdb => 'schema/PostgreSQL.sql', quickdb => 'schema/postgresql_demo.sql']});
    my $dbh = $db->connect('quickdb', AutoCommit => 1, RaiseError => 1);
    my $schema = Test2::Harness::UI::Schema->connect({dbh_maker => sub { $dbh }});

    require Test2::Harness::UI::Import;
    my $import = Test2::Harness::UI::Import->new(schema => $schema);

    open(my $fh, '<', 't/simple.json') or die "Could not open simple.json: $!";
    my $json = join '' => <$fh>;
    close($fh);
    $import->import_events($json);

    my $self = bless {
        db => $db,
        dbh => $dbh,
        schema => $schema,
    }, $class;

    $ctx->release;

    return $self;
}

sub db      { $_[0]->{db} }
sub dbh     { $_[0]->{dbh} }
sub schema  { $_[0]->{schema} }

sub DESTROY {
    my $self = shift;

    return unless $self->{schema};

    local ($@, $!, $?, $^E);

    eval { $self->{schema}->storage->dbh->disconnect };
}

1;
