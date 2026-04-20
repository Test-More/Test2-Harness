package App::Yath2::Options::WebServer;
use strict;
use warnings;

# TODO: Stage: Server/UI scope deferred. All options commented; kept in tree
# to avoid drift.

our $VERSION = '2.000011';

use Getopt::Yath;

# TODO: Server deferred — restore include when DB scope returns
# include_options(
#     'App::Yath2::Options::DB',
# );

option_group {group => 'webserver', category => "Web Server Options"} => sub {
    # TODO: Server deferred — activate --launcher when Server/UI returns
    # option launcher => (
    #     type => 'Scalar',
    #     default => sub {
    #         return 'Starman' if eval { require Starman; 1 };
    #         return undef;
    #     },
    #     description => 'Command to use to launch the server (--server argument to Plack::Runner) ',
    #     notes => "You can pass custom args to the launcher after a '::' like `yath server [ARGS] [LOG FILES(s)] :: [LAUNCHER ARGS]`",
    #     default_text => "Will use 'Starman' unless you specify something else. Will die if nothing is specified and Starman is not installed.",
    # );

    # TODO: Server deferred — activate --port-command when Server/UI returns
    # option port_command => (
    #     type => 'Scalar',
    #     description => 'Command to run that returns a port number.',
    # );

    # TODO: Server deferred — activate --port when Server/UI returns
    # option port => (
    #     type => 'Scalar',
    #     description => 'Port to listen on.',
    #     notes => 'This is passed to the launcher via `launcher --port PORT`',
    #     default => sub {
    #         my ($option, $settings) = @_;
    #
    #         if (my $cmd = $settings->webserver->port_command) {
    #             local $?;
    #             my $port = `$cmd`;
    #             die "Port command `$cmd` exited with error code $?.\n" if $?;
    #             die "Port command `$cmd` did not return a valid port.\n" unless $port;
    #             chomp($port);
    #             die "Port command `$cmd` did not return a valid port: $port.\n" unless $port =~ m/^\d+$/;
    #             return $port;
    #         }
    #
    #         return 8080;
    #     },
    # );

    # TODO: Server deferred — activate --host when Server/UI returns
    # option host => (
    #     type => 'Scalar',
    #     default => 'localhost',
    #     description => "Host/Address to bind to, default 'localhost'.",
    # );

    # TODO: Server deferred — activate --workers when Server/UI returns
    # option workers => (
    #     type => 'Scalar',
    #     default => sub { eval { require System::Info; System::Info->new->ncore } || 5 },
    #     default_text => "5, or number of cores if System::Info is installed.",
    #     description => 'Number of workers. Defaults to the number of cores, or 5 if System::Info is not installed.',
    #     notes => 'This is passed to the launcher via `launcher --workers WORKERS`',
    # );

    # TODO: Server deferred — activate --importers when Server/UI returns
    # option importers => (
    #     type => 'Scalar',
    #     default => 2,
    #     description => 'Number of log importer processes.',
    # );

    # TODO: Server deferred — activate --launcher-args when Server/UI returns
    # option launcher_args => (
    #     type => 'List',
    #     initialize => sub { [] },
    #     description => "Set additional options for the loader.",
    #     notes => "It is better to put loader arguments after '::' at the end of the command line.",
    #     long_examples => [' "--reload"', '="--reload"'],
    # );
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::WebServer - FIXME

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

