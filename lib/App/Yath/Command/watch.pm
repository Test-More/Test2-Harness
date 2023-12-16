package App::Yath::Command::watch;
use strict;
use warnings;

our $VERSION = '2.000000';

use Time::HiRes qw/sleep/;

use App::Yath::Client;

use Test2::Harness::Util::LogFile;

use Test2::Harness::IPC::Util qw/pid_is_running set_procname/;
use Test2::Harness::Util::JSON qw/decode_json/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw{
    +client
    +renderers
};

use Getopt::Yath;
include_options(
    'App::Yath::Options::Yath',
    'App::Yath::Options::IPC',
    'App::Yath::Options::Renderer',
);

sub starts_runner            { 0 }
sub starts_persistent_runner { 0 }

sub args_include_tests { 0 }

sub group { 'daemon' }

sub summary { "Watch/Tail a test runner" }

sub description {
    return <<"    EOT";
Tails the log from a running yath daemon
    EOT
}

sub process_name { "watcher" }

sub client {
    my $self = shift;
    return $self->{+CLIENT} //= App::Yath::Client->new(settings => $self->settings);
}

sub renderers {
    my $self = shift;

    return $self->{+RENDERERS} if $self->{+RENDERERS};

    my $settings = $self->settings;

    my $verbose = 2;
    $verbose = 0 if $settings->renderer->quiet;
    return $self->{+RENDERERS} //= App::Yath::Options::Renderer->init_renderers($settings, verbose => $verbose, progress => 0);
}

sub run {
    my $self = shift;

    set_procname(
        set => [$self->process_name],
        prefix => $self->{+SETTINGS}->harness->procname_prefix,
    );

    return $self->render_log();
}

sub render_log {
    my $self = shift;
    my ($cb) = @_;

    my $renderers = $self->renderers;
    my $client    = $self->client;
    my $pid       = $client->send_and_get('pid');

    my $lf = Test2::Harness::Util::LogFile->new(client => $client);

    my $sig = 0;
    $SIG{INT} = sub { $sig++ };

    while (!$sig && pid_is_running($pid)) {
        $cb->() if $cb;

        my @events = $lf->poll;
        for my $event (@events) {
            $_->render_event($event) for @$renderers;
        }

        next if @events;

        sleep(0.2);
    }

    return 0;
}

1;
