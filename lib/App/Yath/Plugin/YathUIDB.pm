package App::Yath::Plugin::YathUIDB;
use strict;
use warnings;

use Test2::Harness::UI::Util qw/config_from_settings/;
use Test2::Harness::Util::JSON qw/decode_json/;

use App::Yath::Options;
use parent 'App::Yath::Plugin';

option_group {prefix => 'yathui', category => "YathUI Options"} => sub {
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

    option flush_interval => (
        type => 's',
        long_examples => [' 2', ' 1.5'],
        description => 'When buffering DB writes, force a flush when an event is recieved at least N seconds after the last flush.',
    );

    option buffering => (
        type => 's',
        long_examples => [ ' none', ' job', ' diag', ' run' ],
        description => 'Type of buffering to use, if "none" then events are written to the db one at a time, which is SLOW',
        default => 'diag',
    );

    option coverage => (
        type => 'b',
        description => 'Pull coverage data directly from the database (default: off)',
        default => 0,
    );

    option durations => (
        type => 'b',
        description => 'Pull duration data directly from the database (default: off)',
        default => 0,
    );

    option publisher => (
        type => 's',
        description => 'When using coverage or duration data, only use data uploaded by this user',
    );
};

sub coverage_data {
    my ($plugin, $changed, $settings) = @_;
    my $ydb = $settings->prefix('yathui-db') or return;
    return unless $ydb->coverage;

    my $config  = config_from_settings($settings);
    my $schema  = $config->schema;
    my $pname   = $settings->yathui->project                            or die "yathui-project is required.\n";
    my $project = $schema->resultset('Project')->find({name => $pname}) or die "Invalid project '$pname'.\n";

    my $field = $project->coverage(user => $ydb->publisher) // return;
    return $field->data;
}

sub duration_data {
    my ($plugin, $settings) = @_;
    my $ydb = $settings->prefix('yathui-db') or return;
    return unless $ydb->durations;

    my $config = config_from_settings($settings);
    my $schema = $config->schema;
    my $pname   = $settings->yathui->project                            or die "yathui-project is required.\n";
    my $project = $schema->resultset('Project')->find({name => $pname}) or die "Invalid project '$pname'.\n";

    my %args = (user => $ydb->publisher);
    if (my $yui = $settings->prefix('yathui')) {
        $args{short}  = $yui->medium_duration;
        $args{medium} = $yui->long_duration;
        # TODO
        #$args{median} = $yui->median_durations;
    }

    return $project->durations(%args);
}

1;
