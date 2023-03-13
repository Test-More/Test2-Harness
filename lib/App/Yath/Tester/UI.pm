package App::Yath::Tester::UI;
use strict;
use warnings;

BEGIN { $ENV{T2_HARNESS_UI_ENV} = 'dev' }

use DBIx::QuickDB;
use Test2::Harness::UI::Config;
use Test2::AsyncSubtest;

use Test2::API qw/context/;
use Test2::Tools::QuickDB;
use Test2::Tools::Basic qw/note/;

use Carp qw/croak/;
use Time::HiRes qw/sleep/;
use Test2::Util qw/pkg_to_file/;
use Test2::Harness::UI::Util qw/dbd_driver qdb_driver share_dir share_file/;
use Test2::Harness::UI::UUID qw/gen_uuid/;
use Scope::Guard qw/guard/;
use File::Temp qw/tempfile/;

use Importer Importer => 'import';

our @EXPORT = qw/start_yathui_server/;

use Test2::Harness::UI::Util::HashBase qw{
    +schema <db <dsn <config <socket <port +_starman_pid
};

our $DRIVER = skipall_unless_can_db(['PostgreSQL', 'MySQL']);
$DRIVER =~ s{^.*::}{}g;
note("Using driver '$DRIVER'");

sub start_yathui_server {
    return __PACKAGE__->new(@_);
}

sub schema { shift->config->schema }

my $ID = 1;
sub init {
    my $self = shift;

    unless ($self->{+PORT}) {
        my ($fh, $name) = tempfile("YathUITestSocket-XXXXXXXX", SUFFIX => '.sock', TMPDIR => 1, UNLINK => 1);
        $self->{+SOCKET} = $name;
        close($fh);
    }

    my $schema = $self->{+SCHEMA} //= $DRIVER;
    skipall_unless_can_db($schema);

    my $id = $ID++;
    my $db = DBIx::QuickDB->build_db("harness_ui_${id}_$$" => {driver => qdb_driver($schema), dbd_driver => dbd_driver($schema)});
    $self->{+DB} = $db;

    my $dbh = $db->connect('quickdb', AutoCommit => 1, RaiseError => 1);
    $dbh->do('CREATE DATABASE harness_ui') or die "Could not create db " . $dbh->errstr;

    $db->load_sql(harness_ui => share_file('schema/' . $schema . '.sql'));

    my $dsn = $db->connect_string('harness_ui');
    $self->{+DSN} = $dsn;

    my $config = Test2::Harness::UI::Config->new(
        dbi_dsn     => $dsn,
        dbi_user    => '',
        dbi_pass    => '',
        single_user => 1,
        show_user   => 1,
        email       => 'exodist7@gmail.com',
    );
    $self->{+CONFIG} = $config;

    my $pid = fork // die "Could not fork: $!";

    unless ($pid) {
        my $guard = guard {
            warn "Scope Leak in starman";
            posix::_exit(255);
        };

        local $ENV{HARNESS_UI_DSN} = $dsn;
        local $ENV{YATH_UI_SCHEMA} = $schema;

        require(pkg_to_file("Test2::Harness::UI::Schema::$schema"));
        my $user = $config->schema->resultset('User')->create({username => 'root', password => 'root', realname => 'root', user_id => gen_uuid()});
        my $project = $config->schema->resultset('Project')->create({name => 'test', project_id => gen_uuid()});

        exec('starman', '-Ilib', '--listen' => ($self->{+PORT} ? ":$self->{+PORT}" : $self->{+SOCKET}), '--workers', 5, share_file('psgi/test.psgi')),
    }

    $self->{+_STARMAN_PID} = $pid;

    return $self if $self->{+PORT};

    my $interval = 0.2;
    my $counter = 0;
    until (-S $self->{+SOCKET}) {
        sleep $interval;
        $counter += $interval;

        # Only wait 20 seconds;
        croak "Timed out waiting for starman" if $counter >= 20;
    }

    return $self;
}

sub subtest {
    my $self = shift;
    my ($name, $sub) = @_;

    my $ctx = context();

    my $ast = Test2::AsyncSubtest->new(name => $name);
    $ast->run_fork($sub);
    $ast->finish;

    $ctx->release;
}

sub DESTROY {
    my $self = shift;

    my $pid = $self->{+_STARMAN_PID} or return;

    local $?;
    kill('TERM', $pid);
    waitpid($pid, 0);

    return;
}

1;
