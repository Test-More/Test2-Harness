package Test2::Harness2::Role::Credentials;
use v5.38;

our $VERSION = '2.000000';

use Role::Tiny;

requires 'connect';

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Credentials - Role for objects that supply a DB connection.

=head1 DESCRIPTION

A L<Role::Tiny> role consumed by deployment-specific credential objects that
know how to produce a fresh L<DBI> database handle on demand.

L<Test2::Harness2> duck-types against this contract when a credentials object
is passed: if the object has a C<connect> method, it is called each time a new
handle is needed.

=head1 SYNOPSIS

    package MyApp::DBCredentials;
    use v5.38;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Credentials';

    sub connect ($self) {
        return DBI->connect($self->dsn, $self->user, $self->pass,
            {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    }

    # Elsewhere:
    my $h = Test2::Harness2->new(credentials => MyApp::DBCredentials->new(...));
    my $con = $h->connection;

=head1 REQUIRED METHODS

=over 4

=item connect

Must return a fresh, open L<DBI> database handle each time it is called.
The returned handle must have C<RaiseError> enabled and C<PrintError>
disabled. C<AutoCommit> should be enabled unless the caller manages
transactions explicitly.

=back

=cut

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
