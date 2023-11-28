package Getopt::Yath::Settings;
use strict;
use warnings;

our $VERSION = '2.000000';

use Getopt::Yath::Settings::Group;
use Carp();

sub new {
    my $class = shift;
    my $self = @_ > 1 ? { @_ } : $_[0];

    bless($self, $class);

    Getopt::Yath::Settings::Group->new($_) for values %$self;

    return $self;
}

sub check_group { $_[0]->{$_[1]} ? 1 : 0 }

sub group {
    my $self = shift;
    my ($group, $vivify) = @_;

    return $self->{$group} if $self->{$group};

    return $self->{$group} = Getopt::Yath::Settings::Group->new()
        if $vivify;

    Carp::croak("The '$group' group is not defined");
}

sub create_group {
    my $self = shift;
    my ($name, @vals) = @_;

    return $self->{$name} = Getopt::Yath::Settings::Group->new(@vals > 1 ? { @vals } : $vals[0]);
}

sub delete_group {
    my $self = shift;
    my ($name) = @_;

    delete $self->{$name};
}

our $AUTOLOAD;
sub AUTOLOAD {
    my $this = shift;

    my $group = $AUTOLOAD;
    $group =~ s/^.*:://g;

    return if $group eq 'DESTROY';

    Carp::croak("Method $group() must be called on a blessed instance") unless ref($this);

    $this->group($group);
}

sub TO_JSON {
    my $self = shift;
    return {%$self};
}

1;
