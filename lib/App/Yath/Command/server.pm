package App::Yath::Command::server;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub summary     { "Start a yath web server" }
sub description { "Starts a web server that can be used to view test runs in a web browser" }
sub group       { "server" }

sub cli_args { "[log1.jsonl[.gz|.bz2] [log2.jsonl[.gz|.bz2]]]" }
sub cli_dot  { "[:: STARMAN/PLACKUP ARGS]" }

sub accepts_dot_args { 1 }

sub set_dot_args {
    my $class = shift;
    my ($settings, $dot_args) = @_;
    push @{$settings->server->launcher_args} => @$dot_args;
    return;
}

use Getopt::Yath;
include_options(
    'App::Yath::Options::Yath',
    'App::Yath::Options::DB',
    'App::Yath::Options::Term',
);

option_group {group => 'server', category => "Server Options"} => sub {
    option ephemeral => (
        type => 'Auto',
        autofill => 'Auto',
        long_examples => ['', '=Auto', '=PostgreSQL', '=MySQL'],
        description => "Use a temporary 'ephemeral' database that will be destroyed when the server exits.",
        autofill_text => 'If no db type is specified it will use "auto" which will try PostgreSQL first, then MySQL.',
        allowed_values => [qw/Auto PostgreSQL MySQL/],
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

    option launcher => (
        type => 'Scalar',
        default => 'starman',
        description => 'Command to use to launch the server `<launcher> path/to/share/psgi/yath.psgi`',
        notes => "You can pass custom args to the launcher after a '::' like `yath server [ARGS] [LOG FILES(s)]:: [LAUNCHER ARGS]`",
    );

    option port_command => (
        type => 'Scalar',
        description => 'Command to run that returns a port number.',
    );

    option port => (
        type => 'Scalar',
        description => 'Port to listen on.',
        notes => 'This is passed to the launcher via `launcher --port PORT`',
        default => sub {
            my ($option, $settings) = @_;

            if (my $cmd = $settings->server->port_command) {
                local $?;
                my $port = `$cmd`;
                die "Port command `$cmd` exited with error code $?.\n" if $?;
                die "Port command `$cmd` did not return a valid port.\n" unless $port;
                chomp($port);
                die "Port command `$cmd` did not return a valid port: $port.\n" unless $port =~ m/^\d+$/;
                return $port;
            }

            return 8080;
        },
    );

    option workers => (
        type => 'Scalar',
        default => sub { eval { require System::Info; System::Info->new->ncore } || 5 },
        default_text => "5, or number of cores if System::Info is installed.",
        description => 'Number of workers. Defaults to the number of cores, or 5 if System::Info is not installed.',
        notes => 'This is passed to the launcher via `launcher --workers WORKERS`',
    );

    option importers => (
        type => 'Scalar',
        default => 2,
        description => 'Number of log importer processes.',
    );

    option launcher_args => (
        type => 'List',
        initialize => sub { [] },
        description => "Set additional options for the loader.",
        notes => "It is better to put loader arguments after '::' at the end of the command line.",
        long_examples => [' "--reload"', '="--reload"'],
    );
};

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

