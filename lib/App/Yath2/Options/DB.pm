package App::Yath2::Options::DB;
use strict;
use warnings;

# TODO: Stage: DB namespace deferred out of this plan (PLAN Stage 6 / 19 audit).
# All options commented until App::Yath2::DB is revisited.

our $VERSION = '2.000011';

use Getopt::Yath;

option_group {group => 'db', prefix => 'db', category => "Database Options"} => sub {
    # TODO: DB deferred — activate --db-config when App::Yath2::DB returns
    # option config => (
    #     type => 'Scalar',
    #     description => "Module that implements 'MODULE->yath_db_config(%params)' which should return a App::Yath2UI::Schema::Config instance.",
    #     from_env_vars => [qw/YATH_DB_CONFIG/],
    # );

    # TODO: DB deferred — activate --db-driver when App::Yath2::DB returns
    # option driver => (
    #     type => 'Scalar',
    #     description => "DBI Driver to use",
    #     long_examples => [' Pg', ' PostgreSQL', ' MySQL', ' MariaDB', ' Percona', ' SQLite'],
    #     from_env_vars => [qw/YATH_DB_DRIVER/],
    # );

    # TODO: DB deferred — activate --db-name when App::Yath2::DB returns
    # option name => (
    #     type => 'Scalar',
    #     description => 'Name of the database to use',
    #     from_env_vars => [qw/YATH_DB_NAME/],
    # );

    # TODO: DB deferred — activate --db-user when App::Yath2::DB returns
    # option user => (
    #     type => 'Scalar',
    #     description => 'Username to use when connecting to the db',
    #     from_env_vars => [qw/YATH_DB_USER USER/],
    # );

    # TODO: DB deferred — activate --db-pass when App::Yath2::DB returns
    # option pass => (
    #     type => 'Scalar',
    #     description => 'Password to use when connecting to the db',
    #     from_env_vars => [qw/YATH_DB_PASS/],
    # );

    # TODO: DB deferred — activate --db-dsn when App::Yath2::DB returns
    # option dsn => (
    #     type => 'Scalar',
    #     description => 'DSN to use when connecting to the db',
    #     from_env_vars => [qw/YATH_DB_DSN/],
    # );

    # TODO: DB deferred — activate --db-host when App::Yath2::DB returns
    # option host => (
    #     type => 'Scalar',
    #     description => 'hostname to use when connecting to the db',
    #     from_env_vars => [qw/YATH_DB_HOST/],
    # );

    # TODO: DB deferred — activate --db-port when App::Yath2::DB returns
    # option port => (
    #     type => 'Scalar',
    #     description => 'port to use when connecting to the db',
    #     from_env_vars => [qw/YATH_DB_PORT/],
    # );

    # TODO: DB deferred — activate --db-socket when App::Yath2::DB returns
    # option socket => (
    #     type => 'Scalar',
    #     description => 'socket to use when connecting to the db',
    #     from_env_vars => [qw/YATH_DB_SOCKET/],
    # );
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::DB - Options used for database connections.

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

