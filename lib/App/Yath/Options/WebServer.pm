package App::Yath::Options::WebServer;
use strict;
use warnings;

our $VERSION = '2.000001';

use Getopt::Yath;

include_options(
    'App::Yath::Options::DB',
);

option_group {group => 'webserver', category => "Web Server Options"} => sub {
    option launcher => (
        type => 'Scalar',
        default => sub { eval { require Starman; 1 } ? 'Starman' : undef },
        description => 'Command to use to launch the server (--server argument to Plack::Runner) ',
        notes => "You can pass custom args to the launcher after a '::' like `yath server [ARGS] [LOG FILES(s)] :: [LAUNCHER ARGS]`",
        default_text => "Will use 'Starman' if it installed otherwise whatever Plack::Runner uses by default.",
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

            if (my $cmd = $settings->webserver->port_command) {
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

    option host => (
        type => 'Scalar',
        default => 'localhost',
        description => "Host/Address to bind to, default 'localhost'.",
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

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::WebServer - FIXME

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

