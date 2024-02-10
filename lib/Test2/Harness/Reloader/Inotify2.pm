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
};

sub start {
    my $self = shift;

    my $watcher = Linux::Inotify2->new;
    $watcher->blocking(0);
    $self->{+WATCHER} = $watcher;

    return $self->SUPER::start(@_);
}

sub stop {
    my $self = shift;
    delete $self->{+WATCHER};
    return $self->SUPER::stop(@_);
}

sub do_watch {
    my $self = shift;
    my ($file, $val) = @_;

    my $watcher = $self->{+WATCHER} or return;
    $watcher->watch($file, $MASK, sub { $self->notify(@_) });
    return $val;
}

sub changed_files {
    my $self = shift;

    my $watcher = $self->{+WATCHER} // croak "Reloader is not started yet";

    my @out;
    my %seen;
    no warnings 'once';
    local *notify = sub {
        my $self = shift;
        my ($e) = @_;

        my $file = $e->fullname();
        return unless $file;
        next if $seen{$file}++;
        push @out => $file;
    };

    $watcher->poll;

    return \@out;
}

1;
