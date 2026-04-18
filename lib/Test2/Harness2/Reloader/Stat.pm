package Test2::Harness2::Reloader::Stat;
use strict;
use warnings;

our $VERSION = '2.000011';

use Time::HiRes qw/stat time/;

use Test2::Harness2::Util qw/clean_path/;

use parent 'Test2::Harness2::Reloader';
use Object::HashBase qw{
    <last_check_stamp
    <times
    <min_interval
};

sub init {
    my $self = shift;

    $self->{+TIMES}            //= {};
    $self->{+LAST_CHECK_STAMP} //= 0;
    $self->{+MIN_INTERVAL}     //= 1;

    $self->SUPER::init();
}

sub do_watch {
    my $self = shift;
    my ($file, $val) = @_;

    $self->{+TIMES}->{$file} //= $self->_get_file_times($file);

    return $val;
}

sub _get_file_times {
    my $self = shift;
    my ($file) = @_;

    my @stat = stat(clean_path($file));
    return [$stat[9], $stat[10]];    # mtime, ctime
}

sub changed_files {
    my $self = shift;

    my $time  = time;
    my $last  = $self->{+LAST_CHECK_STAMP} // 0;
    my $delta = $time - $last;

    return if $delta < $self->{+MIN_INTERVAL};
    $self->{+LAST_CHECK_STAMP} = $time;

    my $watched = $self->{+WATCHED} // do {
        require Carp;
        Carp::croak("Reloader is not started yet");
    };

    my @out;
    for my $file (keys %$watched) {
        my $new_times = $self->_get_file_times($file);
        my $old_times = $self->{+TIMES}->{$file} //= $new_times;

        next if defined $old_times->[0]
             && defined $new_times->[0]
             && $old_times->[0] == $new_times->[0]
             && $old_times->[1] == $new_times->[1];

        $self->{+TIMES}->{$file} = $new_times;
        push @out => $file;
    }

    return \@out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Reloader::Stat - Portable stat-based file-change detection
for the preload reloader.

=head1 DESCRIPTION

Polling fallback used when L<Linux::Inotify2> is not available. Each call
to C<changed_files> re-stats every watched file and returns the ones whose
mtime or ctime has changed since the last call, rate-limited to at most one
check per C<min_interval> seconds (default: 1).

=head1 ATTRIBUTES

=over 4

=item min_interval => $seconds

Minimum wall-clock delta between real checks. Sub-one-second intervals
are honored on systems with L<Time::HiRes>.

=back

See L<Test2::Harness2::Reloader> for inherited attributes and for the
C<start>/C<stop>/C<watch>/C<check_reload> API.

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
