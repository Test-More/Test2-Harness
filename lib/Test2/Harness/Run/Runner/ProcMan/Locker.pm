package Test2::Harness::Run::Runner::ProcMan::Locker;
use strict;
use warnings;

use Fcntl qw/LOCK_EX LOCK_NB/;
use Carp qw/croak/;
use Time::HiRes qw/sleep/;

use Test2::Harness::Run::Runner::ProcMan::Locker::Lock;

our $VERSION = '0.001042';

use Test2::Harness::Util::HashBase qw{-dir -slots};

sub init {
    my $self = shift;

    croak "'dir' is a required attribute"
        unless $self->{+DIR};

    $self->{+SLOTS} ||= 1;
}

sub DEFAULT_SLOT_PREFIX() { 'slot' }

sub get_lock {
    my $self   = shift;
    my %params = @_;

    my $prefix    = $params{prefix}    || DEFAULT_SLOT_PREFIX;
    my $max_delta = $params{max_delta} || 0;
    my $max       = $params{max} || ($self->{+SLOTS} + $max_delta);

    while (1) {
        for my $slot (1 .. $max) {
            my $file = "$prefix-$slot";
            open(my $fh, '>>', File::Spec->catfile($self->{+DIR}, $file)) or die "Could not open $file lock file: $!";
            flock($fh, LOCK_EX | LOCK_NB) or next;
            return Test2::Harness::Run::Runner::ProcMan::Locker::Lock->new($file, $fh);
        }

        return undef unless $params{block};
        sleep 0.02;
    }
}

*get_medium = \&get_long;
sub get_long {
    my $self   = shift;
    my %params = @_;

    $params{prefix} = 'long';
    $params{max_delta} = $self->{+SLOTS} > 1 ? -1 : 0;

    return $self->get_lock(%params);
}

sub get_immiscible {
    my $self   = shift;
    my %params = @_;

    $params{prefix} = 'immiscible';
    $params{max} = 1;

    return $self->get_lock(%params);
}

sub get_isolation {
    my $self   = shift;
    my %params = @_;

    $params{prefix} = 'isolation';
    $params{max} = 1;

    my $lock = $self->get_lock(%params) or return undef;

    my $flags = LOCK_EX;
    $flags |= LOCK_NB unless $params{block};

    for my $slot (1 .. $self->{+SLOTS}) {
        my $file = DEFAULT_SLOT_PREFIX . "-$slot";

        open(my $fh, '>>', File::Spec->catfile($self->{+DIR}, $file)) or die "Could not open $file lock file: $!";
        flock($fh, $flags) or return undef;

        $lock->add($file, $fh);
    }

    return $lock;
}

1;
