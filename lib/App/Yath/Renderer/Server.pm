package App::Yath::Renderer::Server;
use strict;
use warnings;

use Carp qw/croak/;

use App::Yath::Server;
use App::Yath::Server::Config;
use App::Yath::Schema::RunProcessor;

use Test2::Util qw/pkg_to_file/;
use Test2::Harness::Util qw/mod2file/;
use App::Yath::Server::Util qw/share_dir share_file dbd_driver qdb_driver/;
use Test2::Util::UUID qw/gen_uuid/;

use DBIx::QuickDB;
use Plack::Builder;
use Plack::App::Directory;
use Plack::App::File;
use Plack::Runner;

use Net::Domain qw/hostfqdn/;

our $VERSION = '2.000000';

use parent 'App::Yath::Renderer::DB';
use Test2::Harness::Util::HashBase qw{
    qdb
    app
    port
};

use Getopt::Yath;
option_group {group => 'ui', prefix => 'ui', category => "YathUI Renderer Options"} => sub {
    option user => (
        type => 's',
        description => 'Username to attach to the data sent to the db',
        default => sub { $ENV{USER} },
    );

    option schema => (
        type => 's',
        default => 'PostgreSQL',
        long_examples => [' PostgreSQL', ' MySQL', ' MySQL56'],
        description => "What type of DB/schema to use when using a temporary database",
    );

    option port => (
        type => 's',
        long_examples => [' 8080'],
        description => 'Port to use when running a local server',
        default => 8080,
    );

    option port_command => (
        type => 's',
        long_examples => [' get_port.sh', ' get_port.sh --pid $$'],
        description => 'Use a command to get a port number. "$$" will be replaced with the PID of the yath process',
    );

    option resources => (
        type => 'd',
        description => 'Send resource info (for supported resources) to yathui at the specified interval in seconds (5 if not specified)',
        long_examples => ['', '=5'],
        autofill => 5,
    );

    option only => (
        type => 'b',
        description => 'Only use the YathUI renderer',
    );

    option db => (
        type => 'b',
        description => 'Add the YathUI DB renderer in addition to other renderers',
    );

    option only_db => (
        type => 'b',
        description => 'Only use the YathUI DB renderer',
    );

    option render => (
        type => 'b',
        description => 'Add the YathUI renderer in addition to other renderers',
    );

    post 200 => sub {
        my %params = @_;
        my $settings = $params{settings};

        my $yathui = $settings->yathui;

        if ($settings->check_prefix('display')) {
            my $display = $settings->display;
            if ($yathui->only) {
                $display->renderers = {
                    '@' => ['Test2::Harness::Renderer::UI'],
                    'Test2::Harness::Renderer::UI' => [],
                }
            }
            elsif ($yathui->only_db) {
                $display->renderers = {
                    '@' => ['Test2::Harness::Renderer::UIDB'],
                    'Test2::Harness::Renderer::UIDB' => [],
                }
            }
            elsif ($yathui->render) {
                unless ($display->renderers->{'Test2::Harness::Renderer::UI'}) {
                    push @{$display->renderers->{'@'}} => 'Test2::Harness::Renderer::UI';
                    $display->renderers->{'Test2::Harness::Renderer::UI'} = [];
                }
            }
            elsif ($yathui->db) {
                unless ($display->renderers->{'Test2::Harness::Renderer::UIDB'}) {
                    push @{$display->renderers->{'@'}} => 'Test2::Harness::Renderer::UIDB';
                    $display->renderers->{'Test2::Harness::Renderer::UIDB'} = [];
                }
            }
        }
    };
};

sub init {
    my $self = shift;

    my $settings = $self->{+SETTINGS};

    my $schema = $settings->yathui->schema // 'PostgreSQL';
    require(pkg_to_file("App::Yath::Server::Schema::$schema"));

    my $tmp = $settings->check_prefix('workspace') ? $settings->workspace->workdir : undef;
    local $ENV{TMPDIR} = $tmp if $tmp;

    my $db = DBIx::QuickDB->build_db(harness_ui => {driver => qdb_driver($schema), dbd_driver => dbd_driver($schema)});
    $self->{+QDB} = $db;

    my $dbh = $db->connect('quickdb', AutoCommit => 1, RaiseError => 1);
    $dbh->do('CREATE DATABASE harness_ui') or die "Could not create db " . $dbh->errstr;

    $db->load_sql(harness_ui =>  share_file('schema/' . $schema . '.sql'));

    my $dsn = $db->connect_string('harness_ui');

    $ENV{HARNESS_UI_DSN} = $dsn;

    my $config = App::Yath::Server::Config->new(
        dbi_dsn     => $dsn,
        dbi_user    => '',
        dbi_pass    => '',
        single_user => 1,
        single_run  => 1,
    );

    $self->{+USER} = 'root';
    my $user = $config->schema->resultset('User')->create({username => 'root', password => 'root', realname => 'root'});

    $self->{+PROJECT} = 'default';
    my $proj = $config->schema->resultset('Project')->create({name => 'default'});

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
            App::Yath::Server->new(config => $config)->to_app->(@_);
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

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Renderer::Server - FIXME

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

