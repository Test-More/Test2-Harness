package Test2::Harness::Reloader::Inotify2;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Linux::Inotify2 qw/IN_MODIFY IN_ATTRIB IN_DELETE_SELF IN_MOVE_SELF/;

use Test2::Harness::Util qw/clean_path/;

my $MASK = IN_MODIFY | IN_ATTRIB | IN_DELETE_SELF | IN_MOVE_SELF;

use parent 'Test2::Harness::Reloader';
use Test2::Harness::Util::HashBase qw{
    <watcher
    <watches
};

sub init {
    my $self = shift;

    $self->SUPER::init();
}

sub start {
    my $self = shift;

    my $watcher = Linux::Inotify2->new;
    $watcher->blocking(0);
    $self->{+WATCHER} = $watcher;

    my $watches = $self->find_files_to_watch;
    $self->{+WATCHES} = $watches;

    for my $file (keys %$watches) {
        $watcher->watch($file, $MASK);
    }
}

sub stop {
    my $self = shift;
    delete $self->{+WATCHER};
    delete $self->{+WATCHES};
    return;
}

sub watch {
    my $self = shift;
    my ($file, $cb) = @_;

    my $watcher = $self->{+WATCHER} // croak "Reloader is not started yet";
    my $watches = $self->{+WATCHES} // croak "Reloader has no watches";

    croak "The first argument must be a file" unless $file && -f $file;
    $file = clean_path($file);

    $watcher->watch($file, $MASK) unless $watches->{$file};

    if ($cb) {
        $watches->{$file} = $cb;
    }
    else {
        $watches->{$file} ||= 1;
    }
}

sub file_has_callback {
    my $self = shift;
    my ($file) = @_;

    my $watches = $self->{+WATCHES} // croak "Reloader has no watches";

    my $cb = $watches->{$file} or return undef;
    my $ref = ref($cb) or return undef;
    return $cb if $ref eq 'CODE';
    return undef;
}

sub changed_files {
    my $self = shift;

    my $watcher = $self->{+WATCHER} // croak "Reloader is not started yet";

    my @todo = $watcher->read or return;

    my @out;
    my %seen;
    for my $item (@todo) {
        my $file = $item->fullname();
        next if $seen{$file}++;
        push @out => $file;

        # Make sure watcher keeps a lookout
        $watcher->watch($file, $MASK);
    }

    return \@out;
}

1;
