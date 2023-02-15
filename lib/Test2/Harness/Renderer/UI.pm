package Test2::Harness::Renderer::UI;
use strict;
use warnings;

use Carp qw/croak/;

use Test2::Harness::UI;
use Test2::Harness::UI::Config;
use Test2::Harness::UI::RunProcessor;

use Test2::Util qw/pkg_to_file/;
use Test2::Harness::Util qw/mod2file/;
use Test2::Harness::UI::Util qw/share_dir share_file dbd_driver qdb_driver/;
use Test2::Harness::Util::UUID qw/gen_uuid/;

use DBIx::QuickDB;
use Plack::Builder;
use Plack::App::Directory;
use Plack::App::File;
use Plack::Runner;

use Net::Domain qw/hostfqdn/;

our $VERSION = '0.000130';

use parent 'Test2::Harness::Renderer::UIDB';
use Test2::Harness::Util::HashBase qw{
    qdb
    app
    port
};

sub init {
    my $self = shift;

    my $settings = $self->{+SETTINGS};

    my $schema = $settings->yathui->schema // 'PostgreSQL';
    require(pkg_to_file("Test2::Harness::UI::Schema::$schema"));

    my $tmp = $settings->check_prefix('workspace') ? $settings->workspace->workdir : undef;
    local $ENV{TMPDIR} = $tmp if $tmp;

    my $db = DBIx::QuickDB->build_db(harness_ui => {driver => qdb_driver($schema), dbd_driver => dbd_driver($schema)});
    $self->{+QDB} = $db;

    my $dbh = $db->connect('quickdb', AutoCommit => 1, RaiseError => 1);
    $dbh->do('CREATE DATABASE harness_ui') or die "Could not create db " . $dbh->errstr;

    $db->load_sql(harness_ui =>  share_file('schema/' . $schema . '.sql'));

    my $dsn = $db->connect_string('harness_ui');

    $ENV{HARNESS_UI_DSN} = $dsn;

    my $config = Test2::Harness::UI::Config->new(
        dbi_dsn     => $dsn,
        dbi_user    => '',
        dbi_pass    => '',
        single_user => 1,
        single_run  => 1,
    );

    $self->{+USER} = 'root';
    my $user = $config->schema->resultset('User')->create({username => 'root', password => 'root', realname => 'root', user_id => gen_uuid()});

    $self->{+PROJECT} = 'default';
    my $proj = $config->schema->resultset('Project')->create({name => 'default', project_id => gen_uuid()});

    $self->{+CONFIG} = $config;

    my $port = $settings->yathui->port;
    if (my $cmd = $settings->yathui->port_command) {
        $cmd =~ s/\$\$/$$/;
        chomp($port = `$cmd`);
    }
    $port //= 8080;
    $self->{+PORT} = $port;

    $self->{+APP} = $self->start_app();

    $self->SUPER::init();
}

sub links {
    my $self = shift;

    return $self->{+LINKS} if defined $self->{+LINKS};

    my $port = $self->{+PORT};
    my $fqdn = hostfqdn();

    $self->{+LINKS} = "\nYathUI:\n  local: http://127.0.0.1:$port\n";
    if ($fqdn) {
        $self->{+LINKS} .= "  host:  http://$fqdn:$port\n";
    }

    my $dsn = $self->{+QDB}->connect_string('harness_ui');
    $self->{+LINKS} .= "  DSN:   $dsn\n";

    if ($self->settings->yathui->resources) {
        $self->{+LINKS} .= "\nResource Links:\n";
        my $run_id = $self->settings->run->run_id;

        $self->{+LINKS} .= "  local: http://127.0.0.1:$port/resources/$run_id\n";
        if (my $fqdn = hostfqdn()) {
            $self->{+LINKS} .= "  host:  http://$fqdn:$port/resources/$run_id\n";
        }
    }

    return $self->{+LINKS} .= "\n";
}

sub start_app {
    my $self = shift;

    my $config = $self->{+CONFIG};
    my $settings = $self->{+SETTINGS};

    my $pid = fork // die "Could not fork: $!";
    if ($pid) {
        return $pid;
    }

    setpgrp(0, 0);

    my $app = builder {
        mount '/js'  => Plack::App::Directory->new({root => share_dir('js')})->to_app;
        mount '/css' => Plack::App::Directory->new({root => share_dir('css')})->to_app;
        mount '/favicon.ico' => Plack::App::File->new({file => share_dir('img') . '/favicon.ico'})->to_app;
        mount '/img' => Plack::App::Directory->new({root => share_dir('img')})->to_app;

        mount '/' => sub {
            Test2::Harness::UI->new(config => $config)->to_app->(@_);
        };
    };

    $ENV{PLACK_ENV} = 'test';
    my $r = Plack::Runner->new(access_log => undef, default_middleware => 0);
    my @options = ("--server", "Starman", '--workers' => 10);

    push @options => ('--listen' => ":" . $self->{+PORT});

    $r->parse_options(@options);
    open(STDERR, '>', '/dev/null');
    $r->run($app);

    exit(0);
}

sub finish {
    my $self = shift;
    my $out = $self->SUPER::finish();

    return $out unless kill(0, $self->{+APP});

    print "Leaving yathui server open, press enter to stop it...\n";
    my $in = <STDIN>;

    kill('TERM', $self->{+APP});
    waitpid($self->{+APP}, 0);
    return $out;
}

sub DESTROY {
    my $self = shift;

    if (my $pid = $self->{+APP}) {
        kill('TERM', $pid);
        waitpid($pid, 0);
    }

    $self->SUPER::DESTROY();
}

1;
