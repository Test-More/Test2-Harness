package Test2::Harness::UI::Config;
use strict;
use warnings;

our $VERSION = '0.000028';

use Test2::Util qw/get_tid/;

use Carp qw/croak/;

use Test2::Harness::UI::Util::HashBase qw{
    -_schema
    -dbi_dsn -dbi_user -dbi_pass
    -single_user -single_run -no_upload
    -email
};

sub init {
    my $self = shift;

    croak "'dbi_dsn' is a required attribute"
        unless defined $self->{+DBI_DSN};

    croak "'dbi_user' is a required attribute"
        unless defined $self->{+DBI_USER};

    croak "'dbi_pass' is a required attribute"
        unless defined $self->{+DBI_PASS};
}

sub connect {
    my $self = shift;

    require DBI;

    return DBI->connect(
        $self->{+DBI_DSN},
        $self->{+DBI_USER},
        $self->{+DBI_PASS},
        {AutoCommit => 1, RaiseError => 1}
    );
}

sub schema {
    my $self = shift;

    return $self->{+_SCHEMA} if $self->{+_SCHEMA};

    require Test2::Harness::UI::Schema;

    return $self->{+_SCHEMA} = Test2::Harness::UI::Schema->connect({dbh_maker => sub { $self->connect }});
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Config - UI configuration

=head1 DESCRIPTION

=head1 SYNOPSIS

TODO

=head1 SOURCE

The source code repository for Test2-Harness-UI can be found at
F<http://github.com/Test-More/Test2-Harness-UI/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
