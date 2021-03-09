package App::Yath::Command::ui;
use strict;
use warnings;

our $VERSION = '0.000041';

use Test2::Util qw/pkg_to_file/;

use Test2::Harness::UI::Util qw/share_dir share_file dbd_driver qdb_driver/;

use Test2::Harness::UI::Config;
use Test2::Harness::UI::Importer;
use Test2::Harness::UI;

use Test2::Harness::Util::UUID qw/gen_uuid/;

use DBIx::QuickDB;
use Plack::Builder;
use Plack::App::Directory;
use Plack::App::File;
use Plack::Runner;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw/<log_file/;

use App::Yath::Options;

include_options(
    'App::Yath::Options::PreCommand',
);

option_group {prefix => 'ui', category => "UI Options"} => sub {
    option schema => (
        type => 's',
        default => 'PostgreSQL',
        long_examples => [' PostgreSQL', ' MySQL', ' MySQL56'],
        description => "What type of DB/schema to use",
    );

    option port => (
        type => 's',
        long_examples => [' 8080'],
        description => 'Port to use',
    );

    option port_command => (
        type => 's',
        long_examples => [' get_port.sh', ' get_port.sh --pid $$'],
        description => 'Use a command to get a port number. "$$" will be replaced with the PID of the yath process',
    );
};

sub summary { "Launch a standalone Test2-Harness-UI server for a log file" }

sub group { 'log' }

sub cli_args { "[--] event_log.jsonl[.gz|.bz2]" }

sub description {
    return <<"    EOT";
    EOT
}

sub run {
    my $self = shift;

    my $args = $self->args;
    my $settings = $self->settings;

    my $schema = $settings->ui->schema;
    require(pkg_to_file("Test2::Harness::UI::Schema::$schema"));

    shift @$args if @$args && $args->[0] eq '--';

    $self->{+LOG_FILE} = shift @$args or die "You must specify a log file";
    die "'$self->{+LOG_FILE}' is not a valid log file" unless -f $self->{+LOG_FILE};
    die "'$self->{+LOG_FILE}' does not look like a log file" unless $self->{+LOG_FILE} =~ m/\.jsonl(\.(gz|bz2))?$/;

    my $db = DBIx::QuickDB->build_db(harness_ui => {driver => qdb_driver($schema), dbd_driver => dbd_driver($schema)});

    my $dbh = $db->connect('quickdb', AutoCommit => 1, RaiseError => 1);
    $dbh->do('CREATE DATABASE harness_ui') or die "Could not create db " . $dbh->errstr;
    $db->load_sql(harness_ui => share_file("schema/$schema.sql"));
    my $dsn = $db->connect_string('harness_ui');
    $dbh = undef;

    $ENV{HARNESS_UI_DSN} = $dsn;

    print "DSN: $dsn\n";
    my $config = Test2::Harness::UI::Config->new(
        dbi_dsn     => $dsn,
        dbi_user    => '',
        dbi_pass    => '',
        single_user => 1,
        single_run  => 1,
    );

    my $user = $config->schema->resultset('User')->create({username => 'root', password => 'root', realname => 'root', user_id => gen_uuid()});
    my $proj = $config->schema->resultset('Project')->create({name => 'default', project_id => gen_uuid()});

    $config->schema->resultset('Run')->create({
        run_id     => gen_uuid(),
        user_id    => $user->user_id,
        mode       => 'complete',
        status     => 'pending',
        project_id => $proj->project_id,

        log_file => {
            log_file_id => gen_uuid(),
            name        => $self->{+LOG_FILE},
            local_file  => $self->{+LOG_FILE},
        },
    });

    Test2::Harness::UI::Importer->new(config => $config)->run(1);

    my $app = builder {
        mount '/js'  => Plack::App::Directory->new({root => share_dir('js')})->to_app;
        mount '/css' => Plack::App::Directory->new({root => share_dir('css')})->to_app;
        mount '/favicon.ico' => Plack::App::File->new({file => share_dir('img') . '/favicon.ico'})->to_app;
        mount '/img' => Plack::App::Directory->new({root => share_dir('img')})->to_app;

        mount '/' => sub {
            Test2::Harness::UI->new(config => $config)->to_app->(@_);
        };
    };

    my $port = $settings->ui->port;
    if (my $cmd = $settings->ui->port_command) {
        $cmd =~ s/\$\$/$$/;
        chomp($port = `$cmd`);
    }

    my $r = Plack::Runner->new;
    my @options = ("--server", "Starman");

    push @options => ('--listen' => ":$port") if $port;

    $r->parse_options(@options);
    $r->run($app);

    return 0;
}

1;
