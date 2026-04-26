package App::Yath2::Options::IPC;
use strict;
use warnings;

our $VERSION = '2.000011';

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
);

sub _normalize_protocol {
    my ($v) = @_;
    return $v unless defined $v && length $v;
    return $1 if $v =~ /^\+(.*)$/s;
    return $v if $v =~ /^IPC::Manager::Client::/;
    return "IPC::Manager::Client::$v";
}

option_group {group => 'ipc', category => 'IPC Options'} => sub {
    option dir => (
        name          => 'ipc-dir',
        type          => 'Scalar',
        description   => "Directory for IPC info files (overrides dir-order)",
        from_env_vars => [qw/T2_HARNESS_IPC_DIR YATH_IPC_DIR/],
    );

    option dir_order => (
        name        => 'ipc-dir-order',
        type        => 'List',
        description => "Symbolic search order when --ipc-dir is unset. " . "Symbols: 'user_rc', 'project_rc', 'cwd', 'tempdir'. " . "Raw paths are also accepted.",
        default     => sub { qw/user_rc project_rc cwd tempdir/ },
    );

    option protocol => (
        name          => 'ipc-protocol',
        type          => 'Scalar',
        description   => 'IPC::Manager client driver (default ConnectionUnix). ' . 'Use "+Some::Class" to force a fully qualified namespace.',
        long_examples => [
            ' ConnectionUnix',
            ' AtomicPipe',
            ' UnixSocket',
            ' JSONFile',
            ' MessageFiles',
            ' SharedMem',
            ' SQLite',
            ' +Custom::Driver',
        ],
        default   => sub { 'IPC::Manager::Client::ConnectionUnix' },
        normalize => \&_normalize_protocol,
    );

    option file => (
        name        => 'ipc-file',
        type        => 'Scalar',
        description => 'Explicit IPC info file path. When set, the writer ' . 'writes here regardless of dir-order, and consumer ' . 'commands skip discovery and read this path directly.',
    );
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::IPC - IPC option group for yath commands

=head1 DESCRIPTION

Provides --ipc-dir, --ipc-dir-order, --ipc-protocol, and --ipc-file
options. Driven by the IPC info file design (see
docs/superpowers/specs/2026-04-25-ipc-info-file-design.md).

=cut
