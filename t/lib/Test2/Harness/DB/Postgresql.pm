package Test2::Harness::DB::Postgresql;
use strict;
use warnings;

use Carp qw/croak/;
use IPC::Cmd qw/can_run/;
use File::Temp qw/tempdir/;
use File::Path qw/remove_tree/;
use Time::HiRes qw/sleep/;
use Test2::API qw/context/;

use Test2::Harness::UI::Util::HashBase qw/-dir -pid -my_pid -log -db_dir/;

my ($CREATEDB, $INITDB, $POSTGRES, $PSQL);

BEGIN {
    $CREATEDB = can_run('createdb');
    $INITDB   = can_run('initdb');
    $POSTGRES = can_run('postgres');
    $PSQL     = can_run('psql');
}

sub viable { $CREATEDB && $INITDB && $POSTGRES && $PSQL }

sub import {
    return 1 if viable();

    my $ctx = context();
    $ctx->plan(0, 'SKIP', "no postgresql tools found");
    $ctx->release;
    exit 0;
}

sub _run {
    my $self = shift;
    my ($cmd, $params) = @_;
    my $pid = fork();
    croak "Could not fork" unless defined $pid;

    if ($pid) {
        return $pid if $params->{no_wait};
        local $?;
        my $ret = waitpid($pid, 0);
        my $exit = $?;
        die "waitpid returned $ret" unless $ret == $pid;

        return unless $exit;

        open(my $fh, '<', $self->{+DIR} . '/log') or warn "Failed to open log: $!";
        my $data = eval { join "" => <$fh> };
        croak "Failed to run command '" . join(' ' => @$cmd) . "' ($exit)\n$data";
    }

    unless ($params->{no_log} || $ENV{DB_VERBOSE}) {
        my $log = $self->{+LOG};
        close(STDOUT);
        open(STDOUT, '>&', $log);
        close(STDERR);
        open(STDERR, '>&', $log);
    }

    exec(@$cmd);
}

sub init {
    my $self = shift;

    my $dir = $self->{+DIR} ||= tempdir('PG_DB-XXXXXX', CLEANUP => 1, TMPDIR => 1);
    open(my $log, '>', "$dir/log") or die "Could not open log";
    $self->{+LOG} = $log;

    my $db_dir = $self->{+DB_DIR} = "$dir/db";
    mkdir $db_dir or die "Could not make db dir";
    $self->_run([$INITDB, '-D', $db_dir]);

    open(my $cf, '>>', "$db_dir/postgresql.conf") or die "Could not open config file: $!";
    print $cf "\nunix_socket_directories = '$dir'\nlisten_addresses = ''\n";
    close($cf);

    my $pid = $self->_run([$POSTGRES, '-D', $db_dir], {no_wait => 1});

    my $start = time;
    until (-S "$dir/.s.PGSQL.5432") {
        my $waited = time - $start;
        if ($waited > 10) {
            open(my $fh, '<', $self->{+DIR} . '/log') or warn "Failed to open log: $!";
            my $data = eval { join "" => <$fh> };
            die "Timeout waiting for server:\n$data\n";
        }
        sleep 0.01;
    }

    for my $try ( 1 .. 5 ) {
        print $log "Trying creatdb step try $try of 5\n";
        my $ok = eval { $self->_run([$CREATEDB, '-h', $dir, 'harness_ui']); 1 };
        my $err = $@;
        last if $ok;
        die $@ if $try == 5;
        sleep 1;
    }

    $self->_run([
        $PSQL,
        '-h' => $dir,
        '-v' => 'ON_ERROR_STOP=1',
        '-f' => "schema/postgresql.sql",
        'harness_ui'
    ]);

    $self->import_simple_data();

    my $ctx = context();
    $ctx->note("Database ready: $dir");
    $ctx->release;

    $self->{+MY_PID} = $$;
    $self->{+PID}    = $pid;
    $self->{+DIR}    = $dir;
}

sub connect {
    my $self = shift;
    require Test2::Harness::UI::Schema;

    my $dir = $self->{+DIR} or die "No data dir!";

    return Test2::Harness::UI::Schema->connect("dbi:Pg:dbname=harness_ui;host=$dir", '', '', {AutoCommit => 1});
}

sub DESTROY {
    my $self = shift;

    return unless $self->{+MY_PID} && $self->{+MY_PID} == $$;

    if (my $pid = $self->{+PID}) {
        local $?;
        kill('TERM', $pid);
        waitpid($pid, 0);
    }

    remove_tree($self->{+DIR}, {safe => 1});
}

sub import_simple_data {
    my $self = shift;

    my $schema = $self->connect;

    my $user = $schema->resultset('User')->create({
        username => 'simple',
        password => 'simple',
    });

    require Test2::Harness::UI::Import;
    my $import = Test2::Harness::UI::Import->new(schema => $self->connect);

    open(my $fh, '<', 't/simple.json') or die "Could not open simple.json: $!";
    my $json = join '' => <$fh>;
    close($fh);
    $import->import_events($json);
}

1;
