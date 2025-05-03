package App::Yath::Options::IPC;
use strict;
use warnings;

our $VERSION = '2.000005';

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
        from_env_vars => [qw/T2_HARNESS_IPC_DIR YATH_IPC_DIR/],
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

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::IPC - FIXME

=head1 DESCRIPTION

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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

