package App::Yath::Command::db::sync;
use strict;
use warnings;

our $VERSION = '2.000001';

use DBI;
use App::Yath::Schema::Sync;

use App::Yath::Schema::Util qw/schema_config_from_settings/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub summary     { "Sync runs and associated data from one db to another" }
sub description { "Sync runs and associated data from one db to another" }
sub group       { "database" }

sub cli_args { "" }

use Getopt::Yath;

for my $set (qw/from to/) {
    option_group {group => $set, prefix => $set, category => ucfirst($set) . " Database Options"} => sub {
        option config => (
            type          => 'Scalar',
            description   => "Module that implements 'MODULE->yath_db_config(%params)' which should return a App::Yath::Schema::Config instance.",
            from_env_vars => [qw/YATH_DB_CONFIG/],
        );

        option driver => (
            type          => 'Scalar',
            description   => "DBI Driver to use",
            long_examples => [' Pg', ' PostgreSQL', ' MySQL', ' MariaDB', ' Percona', ' SQLite'],
            from_env_vars => [qw/YATH_DB_DRIVER/],
        );

        option name => (
            type          => 'Scalar',
            description   => 'Name of the database to use',
            from_env_vars => [qw/YATH_DB_NAME/],
        );

        option user => (
            type          => 'Scalar',
            description   => 'Username to use when connecting to the db',
            from_env_vars => [qw/YATH_DB_USER USER/],
        );

        option pass => (
            type          => 'Scalar',
            description   => 'Password to use when connecting to the db',
            from_env_vars => [qw/YATH_DB_PASS/],
        );

        option dsn => (
            type          => 'Scalar',
            description   => 'DSN to use when connecting to the db',
            from_env_vars => [qw/YATH_DB_DSN/],
        );

        option host => (
            type          => 'Scalar',
            description   => 'hostname to use when connecting to the db',
            from_env_vars => [qw/YATH_DB_HOST/],
        );

        option port => (
            type          => 'Scalar',
            description   => 'port to use when connecting to the db',
            from_env_vars => [qw/YATH_DB_PORT/],
        );

        option socket => (
            type          => 'Scalar',
            description   => 'socket to use when connecting to the db',
            from_env_vars => [qw/YATH_DB_SOCKET/],
        );
    };
}

sub run {
    my $self = shift;

    my $args = $self->args;
    my $settings = $self->settings;

    my $from_cfg = schema_config_from_settings($settings, settings_group => 'from');
    my $to_cfg   = schema_config_from_settings($settings, settings_group => 'to');

    my $source_dbh = $self->get_dbh($from_cfg);
    my $dest_dbh   = $self->get_dbh($to_cfg);

    my $sync = App::Yath::Schema::Sync->new();

    my $delta = $sync->run_delta($source_dbh, $dest_dbh);

    $sync->sync(
        from_dbh  => $source_dbh,
        to_dbh    => $dest_dbh,
        run_uuids => $delta->{missing_in_b},

        debug => 1,    # Print a notice for each dumped run_id
    );

    return 0;
}

sub get_dbh {
    my $self = shift;
    my ($cfg) = @_;

    return DBI->connect($cfg->dbi_dsn, $cfg->dbi_user, $cfg->dbi_pass, {AutoCommit => 1, RaiseError => 1});
}

1;

__END__

=head1 POD IS AUTO-GENERATED

