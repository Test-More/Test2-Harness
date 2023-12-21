package App::Yath::Options::IPC;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Harness::Util qw/fqmod/;

use Getopt::Yath;
include_options(
    'App::Yath::Options::Yath',
);

option_group {group => 'ipc', category => 'IPC Options'} => sub {
    option dir_order => (
        name => 'ipc-dir-order',
        type => 'List',
        description => "When finding ipc-dir automatically, search in this order, default: ['base', 'temp']",
        default => sub { qw/base temp/ },
    );

    option dir => (
        name => 'ipc-dir',
        type => 'Scalar',
        description => "Directory for ipc files",
    );

    option prefix => (
        name => 'ipc-prefix',
        type => 'Scalar',
        description => "Prefix for ipc files",
        default => sub { 'IPC' },
    );

    option protocol => (
        name    => 'ipc-protocol',
        type    => 'Scalar',

        long_examples => [' AtomicPipe', ' +Test2::Harness::IPC::Protocol::AtomicPipe', ' UnixSocket', ' IPSocket'],
        description   => 'Specify what IPC Protocol to use. Use the "+" prefix to specify a fully qualified namespace, otherwise Test2::Harness::IPC::Protocol::XXX namespace is assumed.',

        normalize => sub { fqmod($_[0], 'Test2::Harness::IPC::Protocol') },
    );

    option address => (
        name => 'ipc-address',
        type => 'Scalar',
        description => 'IPC address to use (usually auto-generated or discovered)',
    );

    option file => (
        name => 'ipc-file',
        type => 'Scalar',
        description => 'IPC file used to locate instances (usually auto-generated or discovered)',
    );

    option port => (
        name => 'ipc-port',
        type => 'Scalar',
        description => 'Some IPC protocols require a port, otherwise this should be left empty',
    );

    option peer_pid => (
        name => 'ipc-peer-pid',
        type => 'Scalar',
        description => 'Optionally a peer PID may be provided',
    );

    option allow_multiple => (
        name => 'ipc-allow-multiple',
        type => 'Bool',
        default => 0,
        description => 'Normally yath will prevent you from starting multiple persistent runners in the same project, this option will allow you to start more than one.',
    );
};

1;

__END__
