package App::Yath::Plugin::YathUIDB;
use strict;
use warnings;

use App::Yath::Options;
use parent 'App::Yath::Plugin';

option_group {prefix => 'yathui', category => "YathUI Options"} => sub {
    option user => (
        type => 's',
        description => 'Username to attach to the data sent to the db',
        default => sub { $ENV{USER} },
    );
};

option_group {prefix => 'yathui', category => "YathUI Options"} => sub {
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

    option only => (
        type => 'b',
        description => 'Only use the YathUI renderer',
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
            elsif ($yathui->render) {
                unless ($display->renderers->{'Test2::Harness::Renderer::UI'}) {
                    push @{$display->renderers->{'@'}} => 'Test2::Harness::Renderer::UI';
                    $display->renderers->{'Test2::Harness::Renderer::UI'} = [];
                }
            }
        }
    };
};

option_group {prefix => 'yathui-db', category => "YathUI Options"} => sub {
    option config => (
        type => 's',
        description => "Module that implements 'MODULE->yath_ui_config(%params)' which should return a Test2::Harness::UI::Config instance.",
    );

    option driver => (
        type => 's',
        description => "DBI Driver to use",
        long_examples => [' Pg', 'mysql', 'MariaDB'],
    );

    option name => (
        type => 's',
        description => 'Name of the database to use for yathui',
    );

    option user => (
        type => 's',
        description => 'Username to use when connecting to the db',
    );

    option pass => (
        type => 's',
        description => 'Password to use when connecting to the db',
    );

    option dsn => (
        type => 's',
        description => 'DSN to use when connecting to the db',
    );

    option host => (
        type => 's',
        description => 'hostname to use when connecting to the db',
    );

    option port => (
        type => 's',
        description => 'port to use when connecting to the db',
    );

    option socket => (
        type => 's',
        description => 'socket to use when connecting to the db',
    );
};

1;
