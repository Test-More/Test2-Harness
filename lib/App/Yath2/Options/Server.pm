package App::Yath2::Options::Server;
use strict;
use warnings;

# TODO: Stage: Server/UI scope deferred. All options commented; kept in tree
# to avoid drift.

our $VERSION = '2.000011';
use Getopt::Yath;

option_group {group => 'server', category => "Server Options"} => sub {
    # TODO: Server deferred — activate --ephemeral when Server/UI returns
    # option ephemeral => (
    #     type => 'Auto',
    #     autofill => 'Auto',
    #     long_examples => ['', '=Auto', '=PostgreSQL', '=MySQL', '=MariaDB', '=SQLite', '=Percona' ],
    #     description => "Use a temporary 'ephemeral' database that will be destroyed when the server exits.",
    #     autofill_text => 'If no db type is specified it will use "auto" which will try PostgreSQL first, then MySQL.',
    #     allowed_values => [qw/Auto PostgreSQL MySQL MariaDB Percona SQLite/],
    # );

    # TODO: Server deferred — activate --shell when Server/UI returns
    # option shell => (
    #     type => 'Bool',
    #     default => 0,
    #     description => "Drop into a shell where the server and/or database env vars are set so that yath commands will use the started server.",
    # );

    # TODO: Server deferred — activate --daemon when Server/UI returns
    # option daemon => (
    #     type => 'Bool',
    #     default => 0,
    #     description => "Run the server in the background.",
    # );

    # TODO: Server deferred — activate --single-user when Server/UI returns
    # option single_user => (
    #     type => 'Bool',
    #     default => 0,
    #     description => "When using an ephemeral database you can use this to enable single user mode to avoid login and user credentials.",
    # );

    # TODO: Server deferred — activate --single-run when Server/UI returns
    # option single_run => (
    #     type => 'Bool',
    #     default => 0,
    #     description => "When using an ephemeral database you can use this to enable single run mode which causes the server to take you directly to the first run.",
    # );

    # TODO: Server deferred — activate --no-upload when Server/UI returns
    # option no_upload => (
    #     type => 'Bool',
    #     default => 0,
    #     description => "When using an ephemeral database you can use this to enable no-upload mode which removes the upload workflow.",
    # );

    # TODO: Server deferred — activate --email when Server/UI returns
    # option email => (
    #     type => 'Scalar',
    #     description => "When using an ephemeral database you can use this to set a 'from' email address for email sent from this server.",
    # );
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Server - FIXME

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

