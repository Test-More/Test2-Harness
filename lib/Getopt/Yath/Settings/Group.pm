package Getopt::Yath::Settings::Group;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp();

sub new {
    my $class = shift;
    my $self = (@_ != 1) ? { @_ } : $_[0];

    return bless($self, $class);
}

sub all { return %{$_[0]} }

sub check_option { exists($_[0]->{$_[1]}) ? 1 : 0 }

sub option :lvalue {
    my $self = shift;
    my ($option, @vals) = @_;

    Carp::croak("Too many arguments for option()") if @vals > 1;
    Carp::croak("The '$option' option does not exist") unless exists $self->{$option};

    ($self->{$option}) = @vals if @vals;

    return $self->{$option};
}

sub create_option {
    my $self = shift;
    my ($name, $val) = @_;

    $self->{$name} = $val;

    return $self->{$name};
}

sub option_ref {
    my $self = shift;
    my ($name, $create) = @_;

    Carp::croak("The '$name' option does not exist") unless $create || exists $self->{$name};

    return \($self->{$name});
}

sub delete_option {
    my $self = shift;
    my ($name) = @_;

    delete $self->{$name};
}

sub remove_option {
    my $self = shift;
    my ($name) = @_;
    delete ${$self}->{$name};
}

our $AUTOLOAD;
sub AUTOLOAD : lvalue {
    my $this = shift;

    my $option = $AUTOLOAD;
    $option =~ s/^.*:://g;

    return if $option eq 'DESTROY';

    Carp::croak("Method $option() must be called on a blessed instance") unless ref($this);

    $this->option($option, @_);
}

sub TO_JSON {
    my $self = shift;
    return {%$self};
}

1;