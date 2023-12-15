package App::Yath::Command::spawn;
use strict;
use warnings;

our $VERSION = '2.000000';

use Time::HiRes qw/sleep time/;
use File::Temp qw/tempfile/;

use Test2::Harness::Util qw/parse_exit/;

use App::Yath::Client;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub group { 'daemon' }

sub summary { "Launch a perl script from the preloaded environment" }
sub cli_args { "[--] path/to/script.pl [options and args]" }

sub description {
    return <<"    EOT";
This will launch the specified script from the preloaded yath process.

NOTE: environment variables are not automatically passed to the spawned
process. You must use -e or -E (see help) to specify what environment variables
you care about.
    EOT
}

sub load_plugins   { 0 }
sub load_resources { 0 }
sub load_renderers { 0 }

use Getopt::Yath;
option_group {group => 'spawn', category => 'spawn options'} => sub {
    option stage => (
        short => 's',
        type => 'Scalar',
        description => 'Specify the stage to be used for launching the script',
        long_examples => [ ' foo'],
        short_examples => [ ' foo'],
        default => 'BASE',
    );

    option copy_env => (
        short => 'e',
        type => 'List',
        description => "Specify environment variables to pass along with their current values, can also use a regex",
        long_examples => [ ' HOME', ' SHELL', ' /PERL_.*/i' ],
        short_examples => [ ' HOME', ' SHELL', ' /PERL_.*/i' ],
    );

    option env_var => (
        field          => 'env_vars',
        short          => 'E',
        type           => 'Map',
        long_examples  => [' VAR=VAL'],
        short_examples => ['VAR=VAL', ' VAR=VAL'],
        description    => 'Set environment variables for the spawn',
    );
};

include_options(
    'App::Yath::Options::IPC',
    'App::Yath::Options::Yath',
);

sub run {
    my $self = shift;

    my $args = $self->args;
    shift(@$args) if @$args && $args->[0] eq '--';

    my ($script, @argv) = @$args;

    my $settings = $self->settings;
    my $client = App::Yath::Client->new(settings => $settings);

    $client->spawn(
        script => $script,
        argv   => \@argv,
        stage  => $settings->spawn->stage,
        env    => $self->env,
        io_pid => $$,
    );

    my $pid = $client->get_message(blocking => 1)->{'pid'};

    local $SIG{TERM} = sub { kill('TERM', $pid) };
    local $SIG{INT}  = sub { kill('INT',  $pid) };
    local $SIG{HUP}  = sub { kill('HUP',  $pid) };

    my $exit = $client->get_message(blocking => 1)->{'exit'};

    kill($exit->{sig}, $$) if $exit->{sig};

    return $exit->{err} // 0;
}

sub env {
    my $self = shift;

    my $settings = $self->settings;

    my %env;

    for my $var (@{$settings->spawn->copy_env // []}) {
        $env{$var} = $ENV{$var} if exists $ENV{$var};
    }

    if (my $set = $settings->spawn->env_vars) {
        $env{$_} = $set->{$_} for keys %$set;
    }

    return \%env;
}

1;
