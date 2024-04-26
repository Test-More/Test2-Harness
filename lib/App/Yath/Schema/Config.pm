package App::Yath::Schema::Config;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Harness::Util qw/mod2file/;

use Carp qw/croak/;

use Test2::Harness::Util::HashBase qw{
    -_schema
    -dbi_dsn -dbi_user -dbi_pass
};

sub disconnect { shift->schema->storage->disconnect }
sub connect    { shift->schema->storage->dbh }

sub init {
    my $self = shift;

    croak "'dbi_dsn' is a required attribute"
        unless defined $self->{+DBI_DSN};

    croak "'dbi_user' is a required attribute"
        unless defined $self->{+DBI_USER};

    croak "'dbi_pass' is a required attribute"
        unless defined $self->{+DBI_PASS};
}

sub guess_db_driver {
    my $self = shift;

    return 'MySQL' if $self->{+DBI_DSN} =~ m/(mysql|maria|percona)/i;
    return 'PostgreSQL' if $self->{+DBI_DSN} =~ m/(pg|postgre)/i;
    return 'PostgreSQL'; # Default
}

sub db_driver {
    my $self = shift;
    return $ENV{YATH_UI_SCHEMA} //= $self->guess_db_driver;
}

sub schema {
    my $self = shift;

    return $self->{+_SCHEMA} if $self->{+_SCHEMA};

    {
        no warnings 'once';
        unless ($App::Yath::Schema::LOADED) {
            my $schema = $ENV{YATH_UI_SCHEMA} //= $self->guess_db_driver;
            require(mod2file("App::Yath::Schema::$schema"));
        }
    }

    require App::Yath::Schema;

    return $self->{+_SCHEMA} = App::Yath::Schema->connect(
        $self->dbi_dsn,
        $self->dbi_user,
        $self->dbi_pass,
        {AutoCommit => 1, RaiseError => 1},
    );
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::Config - Schema configuration

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

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
