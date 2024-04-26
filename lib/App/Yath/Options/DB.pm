package App::Yath::Options::DB;
use strict;
use warnings;

our $VERSION = '2.000000';

use Getopt::Yath;

option_group {group => 'db', prefix => 'db', category => "Database Options"} => sub {
    option config => (
        type => 'Scalar',
        description => "Module that implements 'MODULE->yath_db_config(%params)' which should return a App::Yath::Schema::Config instance.",
    );

    option driver => (
        type => 'Scalar',
        description => "DBI Driver to use",
        long_examples => [' Pg', 'mysql', 'MariaDB'],
    );

    option name => (
        type => 'Scalar',
        description => 'Name of the database to use',
    );

    option user => (
        type => 'Scalar',
        description => 'Username to use when connecting to the db',
    );

    option pass => (
        type => 'Scalar',
        description => 'Password to use when connecting to the db',
    );

    option dsn => (
        type => 'Scalar',
        description => 'DSN to use when connecting to the db',
    );

    option host => (
        type => 'Scalar',
        description => 'hostname to use when connecting to the db',
    );

    option port => (
        type => 'Scalar',
        description => 'port to use when connecting to the db',
    );

    option socket => (
        type => 'Scalar',
        description => 'socket to use when connecting to the db',
    );
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Schema - Options for using a database.

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

