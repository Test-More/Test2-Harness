package Test2::Harness::UI::Config;
use strict;
use warnings;

use Carp qw/croak/;

use Test2::Harness::UI::Util::HashBase qw{
    -_dbh
    -_schema
    -dbi_dsn -dbi_user -dbi_pass
    -single_user -single_run
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

    return $self->{+_DBH} if $self->{+_DBH};

    require DBI;

    return $self->{+_DBH} = DBI->connect(
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

    my $dbh = $self->connect;

    return $self->{+_SCHEMA} = Test2::Harness::UI::Schema->connect({dbh_maker => sub { $dbh }});
}

1;
