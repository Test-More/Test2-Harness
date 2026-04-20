package Test2::Harness2::ChangeWatcher::Stat;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Time::HiRes qw/stat time/;

use Test2::Harness2::Util qw/clean_path/;

use Object::HashBase qw{
    <watches
    <times
    <last_check_stamp
    <min_interval
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::ChangeWatcher';

# Always usable -- pure perl, no external deps.
sub viable { 1 }

sub init {
    my $self = shift;

    $self->{+WATCHES}          //= {};
    $self->{+TIMES}            //= {};
    $self->{+LAST_CHECK_STAMP} //= 0;
    $self->{+MIN_INTERVAL}     //= 1;
}

sub watch {
    my $self = shift;
    my ($file, $val) = @_;

    croak "watch() requires a file (got: " . (defined $file ? "'$file'" : '(undef)') . ")"
        unless defined $file && length $file;

    $file = clean_path($file);

    croak "watch() requires '$file' to exist"
        unless -e $file;

    $val //= 1;
    $self->{+WATCHES}->{$file} = $val;
    $self->{+TIMES}->{$file} //= $self->_get_file_times($file);

    return $val;
}

sub _get_file_times {
    my $self = shift;
    my ($file) = @_;

    my @stat = stat($file);
    return [$stat[9], $stat[10]];    # mtime, ctime
}

# Return an arrayref of changed files, or undef when the caller
# polled inside the min_interval window. Rate-limiting keeps the
# watcher from pegging the FS on a hot loop.
sub changed_files {
    my $self = shift;

    my $now   = time;
    my $last  = $self->{+LAST_CHECK_STAMP};
    my $delta = $now - $last;

    return undef if $delta < $self->{+MIN_INTERVAL};
    $self->{+LAST_CHECK_STAMP} = $now;

    my $watches = $self->{+WATCHES};

    my @out;
    for my $file (sort keys %$watches) {
        my $new = $self->_get_file_times($file);
        my $old = $self->{+TIMES}->{$file};

        if (   !defined($old->[0])
            || !defined($new->[0])
            || $old->[0] != $new->[0]
            || ($old->[1] // 0) != ($new->[1] // 0))
        {
            $self->{+TIMES}->{$file} = $new;
            push @out => $file;
        }
    }

    return \@out;
}

sub stop {
    my $self = shift;
    $self->{+WATCHES} = {};
    $self->{+TIMES}   = {};
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::ChangeWatcher::Stat - Portable mtime-polling change
watcher for the preload reloader.

=head1 DESCRIPTION

C<stat>-based change detection. Every C<changed_files> call re-stats
every watched file and returns the paths whose mtime or ctime has
moved since the last call, rate-limited to at most one real check
per C<min_interval> seconds (default 1, sub-second values honoured
via L<Time::HiRes>).

Always L<viable|Test2::Harness2::Role::ChangeWatcher/viable>. The
preload resource should prefer the L<inotify
backend|Test2::Harness2::ChangeWatcher::Inotify> on Linux and fall
back to this one when that backend is not available.

=head1 ATTRIBUTES

=over 4

=item min_interval => $seconds

Minimum wall-clock delta between real checks. Default 1.0.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
