package Test2::Harness::Runner::Preload::Stage;
use strict;
use warnings;

our $VERSION = '0.001100';

use Carp qw/croak/;

use Test2::Harness::Util::HashBase qw{
    <name
    <frame
    <children
    <pre_fork_callbacks
    <post_fork_callbacks
    <pre_launch_callbacks
    <load_sequence
};

sub init {
    my $self = shift;

    $self->{+FRAME} //= [caller(1)];

    croak "'name' is a required attribute" unless $self->{+NAME};

    $self->{+CHILDREN} //= [];

    $self->{+PRE_FORK_CALLBACKS}   //= [];
    $self->{+POST_FORK_CALLBACKS}  //= [];
    $self->{+PRE_LAUNCH_CALLBACKS} //= [];

    $self->{+LOAD_SEQUENCE} //= [];
}

sub all_children {
    my $self = shift;

    my @out = @{$self->{+CHILDREN}};

    for (my $i = 0; $i < @out; $i++) {
        my $it = $out[$i];
        push @out => @{$it->children};
    }

    return \@out;
}

sub add_child {
    my $self = shift;
    my ($stage) = @_;
    push @{$self->{+CHILDREN}} => $stage;
}

sub add_pre_fork_callback {
    my $self = shift;
    my ($cb) = @_;
    croak "Callback must be a coderef" unless ref($cb) eq 'CODE';
    push @{$self->{+PRE_FORK_CALLBACKS}} => $cb;
}

sub add_post_fork_callback {
    my $self = shift;
    my ($cb) = @_;
    croak "Callback must be a coderef" unless ref($cb) eq 'CODE';
    push @{$self->{+POST_FORK_CALLBACKS}} => $cb;
}

sub add_pre_launch_callback {
    my $self = shift;
    my ($cb) = @_;
    croak "Callback must be a coderef" unless ref($cb) eq 'CODE';
    push @{$self->{+PRE_LAUNCH_CALLBACKS}} => $cb;
}

sub add_to_load_sequence {
    my $self = shift;

    for my $item (@_) {
        croak "Item '$item' is not a valid preload, must be a module name (scalar) or a coderef"
            unless ref($item) eq 'CODE' || !ref($item);

        push @{$self->{+LOAD_SEQUENCE}} => $item;
    }

    return @_;
}

sub do_load {
    my $self = shift;

    for my $item (@{$self->{+LOAD_SEQUENCE}}) {
        ref($item) eq 'CODE' ? $item->($self) : require(mod2file($item));
    }
}

sub do_pre_fork   { my $self = shift; $_->(@_) for @{$self->{+PRE_FORK_CALLBACKS}} }
sub do_post_fork  { my $self = shift; $_->(@_) for @{$self->{+POST_FORK_CALLBACKS}} }
sub do_pre_launch { my $self = shift; $_->(@_) for @{$self->{+PRE_LAUNCH_CALLBACKS}} }

1;
