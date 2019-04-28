package Test2::Harness::UI::Queries;
use strict;
use warnings;

our $VERSION = '0.000001';

use Carp qw/croak/;

use Test2::Harness::UI::Util::HashBase qw/-config/;

sub init {
    my $self = shift;

    croak "'config' is a required attribute"
        unless $self->{+CONFIG};
}

sub projects {
    my $self = shift;

    my $dbh = $self->{+CONFIG}->connect;

    my $sth = $dbh->prepare('SELECT name FROM projects ORDER BY name ASC');
    $sth->execute() or die $sth->errstr;
    my $rows = $sth->fetchall_arrayref;
    return [map { $_->[0] } @$rows];
}

sub versions   { $_[0]->_from_project(version  => $_[1]) }
sub categories { $_[0]->_from_project(category => $_[1]) }
sub tiers      { $_[0]->_from_project(tier     => $_[1]) }
sub builds     { $_[0]->_from_project(build    => $_[1]) }

sub _from_project {
    my $self = shift;
    my ($field, $project_name) = @_;

    croak "project_name is required"
        unless defined $project_name;

    my $dbh = $self->{+CONFIG}->connect;

    my $schema = $self->{+CONFIG}->schema;
    my $project = $schema->resultset('Project')->find({name => $project_name}) or return [];

    my $sth = $dbh->prepare("SELECT distinct($field) FROM runs WHERE project_id = ? ORDER BY $field ASC");
    $sth->execute($project->project_id) or die $sth->errstr;
    my $rows = $sth->fetchall_arrayref;
    return [map { $_->[0] } @$rows];
}


1;
