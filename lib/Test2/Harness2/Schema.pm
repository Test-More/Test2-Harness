package Test2::Harness2::Schema;
use v5.38;

our $VERSION = '2.000000';

use DBIx::QuickORM;

orm harness => sub {
    # No db here. The harness attaches a db with a connect callback at
    # runtime (see SYNOPSIS) so no credentials live in this file. The
    # schema is introspected from the live database by autofill, which
    # runs lazily when the connection is first built.
    autofill sub {
        autotype 'JSON';
        autotype 'UUID';
        autotype 'DateTime';
        autorow 'Test2::Harness2::Schema::Row';
    };
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Schema - The harness database schema, as a DBIx::QuickORM ORM.

=head1 DESCRIPTION

Defines the harness's L<DBIx::QuickORM> ORM, named C<harness>. The ORM carries
no database and no credentials: the schema is built by autofill, which
introspects the live database the first time a connection is made. JSON, UUID,
and DateTime columns are inflated/deflated automatically, and a row class is
generated per table under C<Test2::Harness2::Schema::Row::> (a hand-written
C<Test2::Harness2::Schema::Row::E<lt>TableE<gt>> is loaded if one exists).

The tables themselves are created from the per-flavor DDL shipped under
C<share/schema/>; autofill only reads what that DDL produced, it never creates
tables. UUID values the harness inserts are generated in Perl with
L<Test2::Util::UUID> (v7); the UUID type here only converts stored values to
and from their canonical form.

Because the ORM has no database, attach one with a C<connect> callback before
asking for a connection. The callback must return a fresh L<DBI> handle each
time it is called.

=head1 SYNOPSIS

C<use>ing this module installs a C<qorm()> accessor into the caller (the
default L<DBIx::QuickORM> export name); C<< qorm(orm => 'harness') >> fetches
the ORM. Attach a database with a C<connect> callback, then ask for the
connection:

    use DBIx::QuickORM only => [qw/db dialect connect db_name/];
    use Test2::Harness2::Schema;

    my $orm = qorm(orm => 'harness');

    $orm->db(db(sub {
        dialect 'SQLite';                       # the dialect is still required
        db_name $path;                          # SQLite database file
        connect(sub { $fresh_dbh });            # any sub returning a NEW DBI handle
    }));

    my $con = $orm->connection;                 # autofill introspects here

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

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
