package App::Yath::Command::db;
use strict;
use warnings;

use App::Yath::Server;
use App::Yath::Schema::Util qw/schema_config_from_settings/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub summary     { "Start a yath database server" }
sub description { "Starts a database that can be used to temporarily store data (data is deleted when server shuts down)" }
sub group       { "db" }

sub cli_args { "" }

use Getopt::Yath;
include_options(
    'App::Yath::Options::Yath',
    'App::Yath::Options::DB',
    'App::Yath::Options::Server',
);

sub run {
    my $self = shift;

    my $args = $self->args;
    my $settings = $self->settings;

    my $daemon = $settings->server->daemon;

    if ($daemon) {
        my $pid = fork // die "Could not fork";
        exit(0) if $pid;

        POSIX::setsid();
        setpgrp(0, 0);

        $pid = fork // die "Could not fork";
        exit(0) if $pid;
    }

    my $ephemeral = $settings->server->ephemeral;
    unless($ephemeral) {
        $ephemeral = 'Auto';
        $settings->server->ephemeral($ephemeral);
    }

    my $config = schema_config_from_settings($settings, ephemeral => $ephemeral);

    my $qdb_params = {
        single_user => $settings->server->single_user // 0,
        single_run  => $settings->server->single_run  // 0,
        no_upload   => $settings->server->no_upload   // 0,
        email       => $settings->server->email       // undef,
    };

    my $server = App::Yath::Server->new(schema_config => $config, qdb_params => $qdb_params);
    $server->start_ephemeral_db;

    my $done = 0;
    $SIG{TERM} = sub { $done++; print "Caught SIGTERM shutting down...\n" unless $daemon; $SIG{TERM} = 'DEFAULT' };
    $SIG{INT}  = sub { $done++; print "Caught SIGINT shutting down...\n"  unless $daemon;  $SIG{INT}  = 'DEFAULT' };

    if ($settings->server->shell) {
        system($ENV{SHELL});
    }
    else {
        $server->qdb->watcher->detach if $daemon;
        sleep 1 until $done;
    }

    $server->stop_ephemeral_db if $server->qdb;

    return 0;
}




# TODO:
# start an ephemeral yath database optionally go to shell

1;

__END__


use feature 'state';


use App::Yath::Schema::Util qw/schema_config_from_settings/;
use App::Yath::Schema::UUID qw/gen_uuid/;

use Test2::Harness::Util qw/clean_path/;

our $VERSION = '2.000000';

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw{
    <server
    <config
};

sub summary     { "Start a yath web server" }
sub description { "Starts a web server that can be used to view test runs in a web browser" }
sub group       { "server" }

sub cli_args { "[log1.jsonl[.gz|.bz2] [log2.jsonl[.gz|.bz2]]]" }
sub cli_dot  { "[:: STARMAN/PLACKUP ARGS]" }

sub accepts_dot_args { 1 }

sub set_dot_args {
    my $class = shift;
    my ($settings, $dot_args) = @_;
    push @{$settings->webserver->launcher_args} => @$dot_args;
    return;
}

use Getopt::Yath;
include_options(
    'App::Yath::Options::Term',
    'App::Yath::Options::Yath',
    'App::Yath::Options::DB',
    'App::Yath::Options::WebServer',
);

option_group {group => 'server', category => "Server Options"} => sub {
    option ephemeral => (
        type => 'Auto',
        autofill => 'Auto',
        long_examples => ['', '=Auto', '=PostgreSQL', '=MySQL', '=MariaDB', '=SQLite', '=Percona' ],
        description => "Use a temporary 'ephemeral' database that will be destroyed when the server exits.",
        autofill_text => 'If no db type is specified it will use "auto" which will try PostgreSQL first, then MySQL.',
        allowed_values => [qw/Auto PostgreSQL MySQL MariaDB Percona SQLite/],
    );

    option shell => (
        type => 'Bool',
        default => 0,
        description => "Drop into a shell where the server and database env vars are set so that yath commands will use the started server.",
    );

    option daemon => (
        type => 'Bool',
        default => 0,
        description => "Run the server in the background.",
    );

    option dev => (
        type => 'Bool',
        default => 0,
        description => 'Launches in "developer mode" which accepts some developer commands while the server is running.',
    );

    option single_user => (
        type => 'Bool',
        default => 0,
        description => "When using an ephemeral database you can use this to enable single user mode to avoid login and user credentials.",
    );

    option single_run => (
        type => 'Bool',
        default => 0,
        description => "When using an ephemeral database you can use this to enable single run mode which causes the server to take you directly to the first run.",
    );

    option no_upload => (
        type => 'Bool',
        default => 0,
        description => "When using an ephemeral database you can use this to enable no-upload mode which removes the upload workflow.",
    );

    option email => (
        type => 'Scalar',
        description => "When using an ephemeral database you can use this to set a 'from' email address for email sent from this server.",
    );
};


sub run {
    my $self = shift;
    my $pid = $$;

    my $args = $self->args;
    my $settings = $self->settings;

    my $ephemeral = $settings->server->ephemeral;

    my $config = $self->{+CONFIG} = schema_config_from_settings($settings, ephemeral => $ephemeral);

    my $qdb_params = {
        single_user => $settings->server->single_user // 0,
        single_run  => $settings->server->single_run  // 0,
        no_upload   => $settings->server->no_upload   // 0,
        email       => $settings->server->email       // undef,
    };

    my $server = $self->{+SERVER} = App::Yath::Server->new(schema_config => $config, $settings->webserver->all, qdb_params => $qdb_params);
    $server->start_server;

    my $done = 0;
    $SIG{TERM} = sub { $done++; print "Caught SIGTERM shutting down...\n"; $SIG{TERM} = 'DEFAULT' };
    $SIG{INT}  = sub { $done++; print "Caught SIGINT shutting down...\n";  $SIG{INT}  = 'DEFAULT' };

    for my $log (@{$args // []}) {
        $self->load_file($config, $log);
    }

    SERVER_LOOP: until ($done) {
        if ($settings->server->dev) {
            $ENV{T2_HARNESS_SERVER_DEV} = 1;

            unless(eval { $done = $self->shell($pid); 1 }) {
                warn $@;
                $done = 1;
            }
        }
        else {
            sleep 1;
        }
    }

    if ($pid == $$) {
        $server->stop_server if $server->pid;
    }
    else {
        die "Scope leak, wrong PID";
    }

    return 0;
}


sub load_file {
    my $self = shift;
    my ($config, $file) = @_;

    $file = clean_path($file);

    state %projects;

    my $project;
    if ($file =~ m/moose/i) {
        $project = 'Moose';
    }
    else {
        $project = $1 if $file =~ m/\b([\w\d]+)\./;
    }

    $project //= "oops";

    unless ($projects{$project}) {
        my $p = $config->schema->resultset('Project')->find_or_create({name => $project, project_idx => gen_uuid()});
        $projects{$project} = $p;
    }

    my $logfile = $config->schema->resultset('LogFile')->create({
        log_file_idx => gen_uuid(),
        name        => $file,
        local_file  => $file =~ m{^/} ? $file : "./demo/$file",
    });

    state $user = $config->schema->resultset('User')->find_or_create({username => 'root', password => 'root', realname => 'root', user_idx => gen_uuid()});

    my $run = $config->schema->resultset('Run')->create({
        run_id     => gen_uuid(),
        user_idx    => $user->user_idx,
        mode       => 'complete',
        buffer     => 'job',
        status     => 'pending',
        project_idx => $projects{$project}->project_idx,

        log_file_idx => $logfile->log_file_idx,
    });

    return $run;
}

sub shell {
    my $self = shift;
    my ($pid, $doneref) = @_;

    # Return that we should exit if the PID is wrong.
    return 1 unless $pid == $$;

    my $settings = $self->settings;
    my $server = $self->{+SERVER};
    my $config = $self->{+CONFIG};

    $SIG{TERM} = sub { $SIG{TERM} = 'DEFAULT'; die "Cought SIGTERM exiting...\n" };
    $SIG{INT}  = sub { $SIG{INT}  = 'DEFAULT'; die "Cought SIGINT exiting...\n" };

    STDERR->autoflush();
    sleep 1;

    my $dsn = $config->dbi_dsn;

    print "DBI_DSN: $dsn\n\n";
    print "\n";
    print "| Yath Server Developer Shell       |\n";
    print "| type 'help', 'h', or '?' for help |\n";

    while(1) {
        print "\n> ";

        my $in = <STDIN>;
        return 1 if !defined($in) && eof(STDIN);
        chomp($in);
        next unless length($in);

        return 1 if $in =~ m/^(q|x|exit|quit)$/;

        if ($in =~ m/^(help|h|\?)(?:\s(.+))?$/) {
            $self->shell_help($1);
            next;
        }

        my ($cmd, $args) = split /\s/, $in, 2;

        my $meth = "shell_$cmd";
        if ($self->can($meth)) {
            eval { $self->$meth($args); 1 } or warn $@;
        }
        else {
            print STDERR "Invalid command '$in'\n";
        }
    }
}

sub shell_help_text { "Show command list." }
sub shell_help {
    my $self = shift;
    my $class = ref($self);
    my $stash = do { no strict 'refs'; \%{"$class\::"} };

    print "\nAvailable commands:\n";
    printf(" %-12s   %s\n", "[q]uit", "Quit the program.");
    printf(" %-12s   %s\n", "e[x]it", "Exit the program.");
    printf(" %-12s   %s\n", "[h]elp", "Show this help.");
    printf(" %-12s   %s\n", "?", "Show this help.");

    for my $sym (sort keys %$stash) {
        next unless $sym =~ m/^shell_(.*)/;
        my $cmd = $1;
        next if $cmd eq 'help';
        next if $sym =~ m/_text$/;
        next unless $self->can($sym);

        my $text = "${sym}_text";
        $text = $self->can($text) ? $self->$text() : 'No description.';
        printf(" %-12s   %s\n", $cmd, $text);
    }
    print "\n";
}

sub shell_reload_text { "Restart web server (does not restart database or importers)." }
sub shell_reload { $_[0]->server->restart_server }

sub shell_reloaddb_text { "Restart database (data is lost)." }
sub shell_reloaddb {
    my $self = shift;

    my $server = $self->server;
    $server->stop_server;
    $server->stop_importers;
    $server->reset_ephemeral_db;
    $server->start_server;
}

sub shell_reloadimp_text { "Restart the importers." }
sub shell_reloadimp { $_[0]->restart_importers() }

sub shell_db_text { "Open the database." }
sub shell_db { $_[0]->server->qdb->shell }

sub shell_load_text { "Load a database file (filename given as argument)" }
sub shell_load { die "TODO: fix me" }

{
    no warnings 'once';
    *shell_r        = \*shell_reload;
    *shell_r_text   = \*shell_reload_text;
    *shell_rdb      = \*shell_reloaddb;
    *shell_rdb_text = \*shell_reloaddb_text;
    *shell_ri       = \*shell_reloadimp;
    *shell_ri_text  = \*shell_reloadimp_text;
}

1;

__END__

use Test2::Util qw/pkg_to_file/;

use App::Yath::Server::Util qw/share_dir share_file dbd_driver qdb_driver/;

use App::Yath::Server::Config;
use App::Yath::Schema::Importer;
use App::Yath::Server;

use App::Yath::Schema::UUID qw/gen_uuid/;

use DBIx::QuickDB;
use Plack::Builder;
use Plack::App::Directory;
use Plack::App::File;
use Plack::Runner;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw/<log_file/;

use Getopt::Yath;

option_group {prefix => 'ui', group => 'ui', category => "UI Options"} => sub {
    option schema => (
        type => 'Scalar',
        default => 'PostgreSQL',
        long_examples => [' PostgreSQL', ' MySQL', ' MySQL56'],
        description => "What type of DB/schema to use",
    );

    option port => (
        type => 'Scalar',
        long_examples => [' 8080'],
        description => 'Port to use',
    );

    option port_command => (
        type => 'Scalar',
        long_examples => [' get_port.sh', ' get_port.sh --pid $$'],
        description => 'Use a command to get a port number. "$$" will be replaced with the PID of the yath process',
    );
};

sub summary { "Launch a standalone Test2-Harness-UI server for a log file" }

sub group { 'ui' }

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
    require(pkg_to_file("App::Yath::Server::Schema::$schema"));

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
    my $config = App::Yath::Server::Config->new(
        dbi_dsn     => $dsn,
        dbi_user    => '',
        dbi_pass    => '',
        single_user => 1,
        single_run  => 1,
    );

    my $user = $config->schema->resultset('User')->create({username => 'root', password => 'root', realname => 'root', user_idx => gen_uuid()});
    my $proj = $config->schema->resultset('Project')->create({name => 'default', project_idx => gen_uuid()});

    $config->schema->resultset('Run')->create({
        run_id     => gen_uuid(),
        user_idx    => $user->user_idx,
        mode       => 'complete',
        status     => 'pending',
        project_idx => $proj->project_idx,

        log_file => {
            log_file_idx => gen_uuid(),
            name        => $self->{+LOG_FILE},
            local_file  => $self->{+LOG_FILE},
        },
    });

    App::Yath::Schema::Importer->new(config => $config)->run(1);

    my $app = builder {
        mount '/js'  => Plack::App::Directory->new({root => share_dir('js')})->to_app;
        mount '/css' => Plack::App::Directory->new({root => share_dir('css')})->to_app;
        mount '/favicon.ico' => Plack::App::File->new({file => share_dir('img') . '/favicon.ico'})->to_app;
        mount '/img' => Plack::App::Directory->new({root => share_dir('img')})->to_app;

        mount '/' => sub {
            App::Yath::Server->new(config => $config)->to_app->(@_);
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

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command::ui - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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

See L<http://dev.perl.org/licenses/>

=cut

