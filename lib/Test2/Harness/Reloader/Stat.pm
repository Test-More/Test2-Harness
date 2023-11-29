package Test2::Harness::Reloader::Stat;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Time::HiRes qw/stat time/;

use Test2::Harness::Util qw/clean_path/;

use parent 'Test2::Harness::Reloader';
use Test2::Harness::Util::HashBase qw{
    <watches
    <last_check_stamp
};

sub init {
    my $self = shift;

    $self->SUPER::init();
}

sub start {
    my $self = shift;

    my $to_watch = $self->find_files_to_watch;

    my %watches;
    for my $f (keys %$to_watch) {
        my $file = clean_path($f);

        my $cb = $to_watch->{$f};
        $cb = ref($cb) ? $cb : undef;

        my $times = $self->_get_file_times($file);

        $watches{$file} = {callback => $cb, times => $times};
    }

    $self->{+WATCHES} = \%watches;
}

sub _get_file_times {
    my $self = shift;
    my ($file) = @_;
    my (undef, undef, undef, undef, undef, undef, undef, undef, undef, $mtime, $ctime) = stat($file);
    return [$mtime, $ctime];
}

sub stop {
    my $self = shift;
    delete $self->{+WATCHES};
    return;
}

sub watch {
    my $self = shift;
    my ($file, $cb) = @_;

    my $watches = $self->{+WATCHES} // croak "Reloader has no watches";

    croak "The first argument must be a file" unless $file && -f $file;
    $file = clean_path($file);

    my $watch = $watches->{$file} //= {times => $self->_get_file_times($file)};
    $watch->{callback} = $cb;

    return;
}

sub file_has_callback {
    my $self = shift;
    my ($file) = @_;

    my $watches = $self->{+WATCHES} // croak "Reloader has no watches";

    my $watch = $watches->{$file} or return undef;
    return $watches->{callback};
}

sub changed_files {
    my $self = shift;

    my $time = time;
    my $last = $self->{+LAST_CHECK_STAMP} // 0;
    my $delta = $time - $last;

    return if $delta < 1;
    $self->{+LAST_CHECK_STAMP} = $time;

    my $watches = $self->{+WATCHES} // croak "Reloader is not started yet";

    my @out;
    for my $file (keys %$watches) {
        my $watch = $watches->{$file};
        my $new_times = $self->_get_file_times($file);
        my $old_times = $watch->{times} //= $new_times;

        next if $old_times->[0] == $new_times->[0] && $old_times->[1] == $new_times->[1];

        # Update so we do not reload twice for the same change
        $watch->{times} = $new_times;

        push @out => $file;
    }

    return \@out;
}

1;
