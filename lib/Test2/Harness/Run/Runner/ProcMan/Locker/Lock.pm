package Test2::Harness::Run::Runner::ProcMan::Locker::Lock;
use strict;
use warnings;

our $VERSION = '0.001042';

sub new {
    my $class = shift;
    my ($file, $fh) = @_;
    return bless([[$file, $fh]], $class);
}

sub add {
    my $self = shift;
    my ($file, $fh) = @_;
    push @$self => [$file, $fh];
}

sub merge {
    my $self = shift;
    my ($add) = @_;
    push @$self => @$add;
}

1;
