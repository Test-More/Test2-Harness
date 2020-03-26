package App::Yath::Command::ui;
use strict;
use warnings;

our $VERSION = '0.000028';

use Test2::Util qw/pkg_to_file/;

use Test2::Harness::UI::Util qw/share_dir share_file/;

use Test2::Harness::UI::Config;
use Test2::Harness::UI::Importer;
use Test2::Harness::UI;

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

sub summary { "Launch a standalone Test2-Harness-UI server for a log file" }

sub group { 'log' }

sub cli_args { "[--] event_log.jsonl[.gz|.bz2]" }

sub description {
    return <<"    EOT";
    EOT
}

sub run {
    my $self = shift;

    my $args     = $self->args;

    shift @$args if @$args && $args->[0] eq '--';

    $self->{+LOG_FILE} = shift @$args or die "You must specify a log file";
    die "'$self->{+LOG_FILE}' is not a valid log file" unless -f $self->{+LOG_FILE};
    die "'$self->{+LOG_FILE}' does not look like a log file" unless $self->{+LOG_FILE} =~ m/\.jsonl(\.(gz|bz2))?$/;

    my $db = DBIx::QuickDB->build_db(harness_ui => {driver => 'PostgreSQL'});

    my $dbh = $db->connect('quickdb', AutoCommit => 1, RaiseError => 1);
    $dbh->do('CREATE DATABASE harness_ui') or die "Could not create db " . $dbh->errstr;
    $db->load_sql(harness_ui => share_file('schema/postgresql.sql'));
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

    my $user = $config->schema->resultset('User')->create({username => 'root', password => 'root', realname => 'root'});
    my $proj = $config->schema->resultset('Project')->create({name => 'default'});

    open(my $lf, '<', $self->{+LOG_FILE}) or die "Could no open log file: $!";
    $config->schema->resultset('Run')->create(
        {
            user_id    => $user->user_id,
            mode       => 'complete',
            status     => 'pending',
            project_id => $proj->project_id,

            log_file => {
                name => $self->{+LOG_FILE},
                data => do { local $/; <$lf> },
            },
        }
    );

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

    my $r = Plack::Runner->new;
    $r->parse_options("--server", "Starman");
    $r->run($app);

    return 0;
}

1;
