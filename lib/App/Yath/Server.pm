package App::Yath::Server;
use strict;
use warnings;

use Carp qw/croak confess/;
use Test2::Harness::Util qw/parse_exit mod2file/;
use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use Plack::Runner;
use DBIx::QuickDB;

use App::Yath::Server::Plack;
use App::Yath::Schema::Importer;

use App::Yath::Util qw/share_file/;
use App::Yath::Schema::Util qw/qdb_driver dbd_driver/;

our $VERSION = '2.000005';

use Test2::Harness::Util::HashBase qw{
    <schema_config

    <root_pid

    +plack
    <pid
    <importer_pids
    <qdb
    <qdb_params

    <importers
    <launcher
    <launcher_args
    <port
    <host
    <workers
};

sub init {
    my $self = shift;

    croak "'schema_config' is a required attribute" unless $self->{+SCHEMA_CONFIG};

    $self->{+QDB_PARAMS} //= {};
}

sub restart_server {
    my $self = shift;
    my ($sig) = @_;

    my $exit = $self->stop_server($sig);
    $self->start_server();

    return $exit;
}

sub stop_server {
    my $self = shift;
    my ($sig) = @_;

    $self->_root_proc_check();

    my $pid = delete $self->{+PID} or croak "No server running";

    return $self->stop_proc($pid, $sig);
}

sub stop_proc {
    my $self = shift;
    my ($pid, $sig) = @_;

    $self->_root_proc_check();

    croak "'pid' is required" unless $pid;
    $sig //= 'TERM';

    local $?;
    kill($sig, $pid);
    my $got = waitpid($pid, 0);
    my $exit = $?;

    croak "waitpid returned '$got', expected '$pid'" unless $got == $pid;
    return parse_exit($exit);
}

sub reset_ephemeral_db {
    my $self = shift;
    my ($sig) = @_;

    my $exit = $self->stop_ephemeral_db($sig);
    $self->start_ephemeral_db();

    return $exit;
}

sub stop_ephemeral_db {
    my $self = shift;
    my ($sig) = @_;

    $self->_root_proc_check();
    $self->stop_server   if $self->{+PID};
    $self->stop_importers if $self->{+IMPORTER_PIDS};

    my $db = delete $self->{+QDB} or croak "No ephemeral db running";

    $db->stop;
}

sub start_ephemeral_db {
    my $self = shift;

    croak "Ephemeral DB already started" if $self->{+QDB};

    $self->{+ROOT_PID} //= $$;
    $self->_root_proc_check();

    my $config = $self->{+SCHEMA_CONFIG};
    my $schema_type = $config->ephemeral // 'Auto';

    my $qdb_args;
    if ($schema_type eq 'Auto') {
        $qdb_args = {drivers => [qdb_driver('PostgreSQL'), qdb_driver('MariaDB'), qdb_driver('MySQL'), qdb_driver('Percona'), qdb_driver('SQLite')]};
        $schema_type = undef;
    }
    else {
        $qdb_args = {driver => qdb_driver($schema_type), dbd_driver => dbd_driver($schema_type)}
    }

    my $db = DBIx::QuickDB->build_db(harness_ui => $qdb_args);
    unless($schema_type) {
        if (ref($db) =~ m/::(PostgreSQL|MariaDB|Percona|SQLite|MySQL)$/) {
            $schema_type = $1;
        }
        else {
            die "$db does not look like PostgreSQL, Percona, MariaDB, SQLite or MySQL";
        }
    }

    my $dbh;
    if ($schema_type =~ m/SQLite/i) {
        $dbh = $db->connect('harness_ui', AutoCommit => 1, RaiseError => 1);
    }
    else {
        $dbh = $db->connect('quickdb', AutoCommit => 1, RaiseError => 1);
        $dbh->do('CREATE DATABASE harness_ui') or die "Could not create db " . $dbh->errstr;
    }

    $db->load_sql(harness_ui => share_file("schema/$schema_type.sql"));
    my $dsn = $db->connect_string('harness_ui');

    $config->push_ephemeral_credentials(dbi_dsn => $dsn, dbi_user => '', dbi_pass => '', schema_type => $schema_type);
    $ENV{YATH_DB_DSN} = $dsn;

    require(mod2file("App::Yath::Schema::$schema_type"));

    my $schema = $config->schema;

    $schema->resultset('User')->create({username => 'root', password => 'root', realname => 'root'});

    my $qdb_params = $self->{+QDB_PARAMS} // {};
    $schema->config(single_user => $qdb_params->{single_user} // 0);
    $schema->config(single_run  => $qdb_params->{single_run}  // 0);
    $schema->config(no_upload   => $qdb_params->{no_upload}   // 0);
    $schema->config(email       => $qdb_params->{email}) if $qdb_params->{email};

    return $self->{+QDB} = $db;
}

sub start_server {
    my $self = shift;
    my %params = @_;

    croak "Server already started with pid $self->{+PID}" if $self->{+PID};

    $self->{+ROOT_PID} //= $$;
    $self->_root_proc_check();

    if ($self->{+SCHEMA_CONFIG}->ephemeral && !$params{no_db} && !$self->{+QDB}) {
        $self->start_ephemeral_db();
    }

    unless ($self->{+IMPORTER_PIDS} || $params{no_importers}) {
        $self->start_importers();
    }

    my $pid = fork // die "Could not fork: $!";

    return $self->{+PID} = $pid if $pid;

    $0 = "yath-web-server";

    my $ok = eval { $self->_do_server_exec(); 1 };
    my $err = $@;

    unless ($ok) {
        eval { warn $err };
        exit 255;
    }

    exit(0);
}

sub _do_server_exec {
    my $self = shift;

    my @options;
    push @options => @{$self->{+LAUNCHER_ARGS} // []};
    push @options => ("--server"  => $self->{+LAUNCHER})              if $self->{+LAUNCHER};
    push @options => ('--listen'  => "$self->{+HOST}:$self->{+PORT}") if $self->{+PORT};
    push @options => ('--workers' => "$self->{+WORKERS}")             if $self->{+WORKERS};

    exec(
        $^X,
        (map {"-I$_"} @INC),
        "-m${ \__PACKAGE__ }",
        '-e' => "${ \__PACKAGE__ }->_do_server_post_exec(\$ARGV[0])",
        encode_json({
            schema_config => $self->{+SCHEMA_CONFIG},
            launcher_options => \@options,
        }),
    );
}

sub _do_server_post_exec {
    my $class = shift;
    my ($json) = @_;

    $0 = "yath-web-server";

    my $data = decode_json($json);

    my $r = Plack::Runner->new;
    $r->parse_options(@{$data->{launcher_options}});

    my $app = App::Yath::Server::Plack->new(
        schema_config => bless($data->{+SCHEMA_CONFIG}, 'App::Yath::Schema::Config'),
    );

    $r->run($app->to_app());

    exit(0);
}

sub restart_importers {
    my $self = shift;
    $self->stop_importers();
    $self->start_importers();
}

sub start_importers {
    my $self = shift;

    local $0 = 'yath-importer';

    croak "Importers already started" if $self->{+IMPORTER_PIDS};

    $self->{+ROOT_PID} //= $$;
    $self->_root_proc_check();

    # Gen uuids here before forking
    my @pids;
    for (1 .. $self->{+IMPORTERS} // 2) {
        push @pids => App::Yath::Schema::Importer->new(config => $self->{+SCHEMA_CONFIG})->spawn();
    }

    $self->{+IMPORTER_PIDS} = \@pids;
}

sub stop_importers {
    my $self = shift;

    my $pids = delete $self->{+IMPORTER_PIDS} or croak "Importers not started";
    $self->_root_proc_check();

    kill('TERM', @$pids);

    for my $pid (@$pids) {
        local $?;
        my $got = waitpid($pid, 0);
        my $exit = $?;

        warn "waitpid returned '$got' expected '$pid'" unless $got == $pid;
        warn "importer process exited with $exit" if $exit;
    }

    return;
}

sub _root_proc_check {
    my $self = shift;
    confess "root_pid is not set, did you start any servers?" unless $self->{+ROOT_PID};
    return if $$ == $self->{+ROOT_PID};
    confess "Attempt to manage processes from the wrong process";
}

sub shutdown {
    my $self = shift;

    $self->_root_proc_check();

    $self->stop_importers()    if $self->importer_pids;
    $self->stop_ephemeral_db() if $self->qdb;
    $self->stop_server()       if $self->pid;
}

sub DESTROY {
    my $self = shift;

    local $?;

    return unless $self->{+ROOT_PID};
    return unless $self->{+ROOT_PID} == $$;

    $self->shutdown();
}

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Server - FIXME

=head1 DESCRIPTION


=head1 SYNOPSIS


=head1 SOURCE

The source code repository for Test2-Harness-UI can be found at
F<https://github.com/Test-More/Test2-Harness-UI/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

=pod

=cut POD NEEDS AUDIT

