package Test2::Harness::Run::Runner::ProcMan::Locker;
use strict;
use warnings;

use Fcntl qw/LOCK_EX LOCK_NB/;
use Carp qw/croak/;
use Time::HiRes qw/sleep/;

use Test2::Harness::Run::Runner::ProcMan::Locker::Lock;

our $VERSION = '0.001041';

use Test2::Harness::Util::HashBase qw{-dir -slots};

sub init {
    my $self = shift;

    croak "'dir' is a required attribute"
        unless $self->{+DIR};

    $self->{+SLOTS} ||= 1;
}

*get_general = \&get_slot;

sub get_slot {
    my $self   = shift;
    my %params = @_;

    while (1) {
        for my $slot (1 .. $self->{+SLOTS}) {
            open(my $fh, '>>', File::Spec->catfile($self->{+DIR}, "slot-$slot")) or die "Could not open slot-$slot lock file: $!";
            flock($fh, LOCK_EX | LOCK_NB) or next;
            return bless([[$slot, $fh]], 'Test2::Harness::Run::Runner::ProcMan::Locker::Lock');
        }

        return undef unless $params{block};
        sleep 0.02;
    }
}

*get_medium = \&get_long;

sub get_long {
    my $self   = shift;
    my %params = @_;
    my $flags  = LOCK_EX;
    $flags |= LOCK_NB unless $params{block};

    return $self->get_slot(@_) if $self->{+SLOTS} < 2;

    for my $slot (2 .. $self->{+SLOTS}) {
        open(my $fh, '>>', File::Spec->catfile($self->{+DIR}, "long-$slot")) or die "Could not open slot-$slot lock file: $!";
        flock($fh, $flags) or next;

        my $slot = $self->get_slot(@_) or return undef;
        push @$slot => ["long-$slot" => $fh];
        return $slot;
    }

    return undef;
}

sub get_immiscible {
    my $self   = shift;
    my %params = @_;
    my $flags  = LOCK_EX;
    $flags |= LOCK_NB unless $params{block};

    open(my $fh, '>>', File::Spec->catfile($self->{+DIR}, 'immiscible')) or die "Could not open immiscible lock file: $!";
    flock($fh, $flags) or return undef;

    my $slot = $self->get_slot(%params) or return undef;

    push @$slot => ['immiscible', $fh];
    return $slot;
}

sub get_isolation {
    my $self   = shift;
    my %params = @_;
    my $flags  = LOCK_EX;
    $flags |= LOCK_NB unless $params{block};

    open(my $iso, '>>', File::Spec->catfile($self->{+DIR}, 'isolation')) or die "Could not open isolation lock file: $!";
    flock($iso, $flags) or return undef;

    my @locks = (['isolation' => $iso]);

    for my $slot (1 .. $self->{+SLOTS}) {
        open(my $fh, '>>', File::Spec->catfile($self->{+DIR}, "slot-$slot")) or die "Could not open slot-$slot lock file: $!";
        flock($fh, $flags) or return undef;
        push @locks => [$slot => $fh];
    }

    return bless(\@locks, 'Test2::Harness::Run::Runner::ProcMan::Locker::Lock');
}

1;
