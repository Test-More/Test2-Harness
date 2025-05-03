package App::Yath::Schema::Config;
use strict;
use warnings;

our $VERSION = '2.000005';

use Test2::Harness::Util qw/mod2file/;

use Carp qw/croak/;

use Test2::Harness::Util::HashBase qw{
    -_schema
    <dbi_dsn <dbi_user <dbi_pass
    <ephemeral
    <ephemeral_stack
};

sub TO_JSON {
    my $self = shift;
    my %data = %$self;

    delete $data{+_SCHEMA};
    delete $data{+EPHEMERAL};
    delete $data{+EPHEMERAL_STACK};

    return \%data;
}

sub disconnect { shift->schema->storage->disconnect }
sub connect    { shift->schema->storage->dbh }

sub init {
    my $self = shift;

    unless ($self->{+EPHEMERAL}) {
        croak "'dbi_dsn' is a required attribute" unless defined $self->{+DBI_DSN};
        croak "'dbi_user' is a required attribute" unless defined $self->{+DBI_USER};
        croak "'dbi_pass' is a required attribute" unless defined $self->{+DBI_PASS};
    }
}

sub _check_for_creds {
    my $self = shift;

    croak "'dbi_dsn' has not been set yet"  unless defined $self->{+DBI_DSN};
    croak "'dbi_user' has not been set yet" unless defined $self->{+DBI_USER};
    croak "'dbi_pass' has not been set yet" unless defined $self->{+DBI_PASS};
}

sub push_ephemeral_credentials {
    my $self = shift;
    my %params = @_;

    push @{$self->{+EPHEMERAL_STACK} //= []} => [@{$self}{DBI_DSN(), DBI_USER(), DBI_PASS()}, delete($self->{+_SCHEMA}), delete($ENV{YATH_DB_SCHEMA})];

    $self->{$_} = $params{$_} // croak "'$_' is a required parameter" for DBI_DSN(), DBI_USER(), DBI_PASS();

    if (my $schema_type = $params{schema_type}) {
        $ENV{YATH_DB_SCHEMA} = $schema_type;
    }

    return;
}

sub pop_ephemeral_credentials {
    my $self = shift;

    my $set = pop(@{$self->{+EPHEMERAL_STACK} // []}) or croak "No db to pop";

    my $schema;
    (@{$self}{DBI_DSN(), DBI_USER(), DBI_PASS()}, $self->{+_SCHEMA}, $schema) = @$set;

    $ENV{YATH_DB_SCHEMA} = $schema if defined $schema;

    delete $self->{+EPHEMERAL_STACK} unless @{$self->{+EPHEMERAL_STACK}};

    return;
}

sub guess_db_driver {
    my $self = shift;

    $self->_check_for_creds();

    return 'SQLite'     if $self->{+DBI_DSN} =~ m/sqlite/i;
    return 'MariaDB'    if $self->{+DBI_DSN} =~ m/maria/i;
    return 'Percona'    if $self->{+DBI_DSN} =~ m/percona/i;
    return 'MySQL'      if $self->{+DBI_DSN} =~ m/mysql/i;
    return 'PostgreSQL' if $self->{+DBI_DSN} =~ m/(pg|postgre)/i;
    return 'PostgreSQL';    # Default
}

sub db_driver {
    my $self = shift;

    $self->_check_for_creds();

    return $ENV{YATH_DB_SCHEMA} //= $self->guess_db_driver;
}

sub schema {
    my $self = shift;

    return $self->{+_SCHEMA} if $self->{+_SCHEMA};

    $self->_check_for_creds();

    {
        no warnings 'once';
        unless ($App::Yath::Schema::LOADED) {
            my $schema = $ENV{YATH_DB_SCHEMA} //= $self->guess_db_driver;
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

=pod

=cut POD NEEDS AUDIT

