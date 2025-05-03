package Test2::Harness::Reloader::Stat;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp qw/croak/;
use Time::HiRes qw/stat time/;

use Test2::Harness::Util qw/clean_path/;

use parent 'Test2::Harness::Reloader';
use Test2::Harness::Util::HashBase qw{
    <last_check_stamp
    <times
};

sub init {
    my $self = shift;

    $self->{+TIMES} //= {};
    $self->{+LAST_CHECK_STAMP} //= 0;

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
    my (undef, undef, undef, undef, undef, undef, undef, undef, undef, $mtime, $ctime) = stat(clean_path($file));
    return [$mtime, $ctime];
}

sub changed_files {
    my $self = shift;

    my $time = time;
    my $last = $self->{+LAST_CHECK_STAMP} // 0;
    my $delta = $time - $last;

    return if $delta < 1;
    $self->{+LAST_CHECK_STAMP} = $time;

    my $watched = $self->{+WATCHED} // croak "Reloader is not started yet";

    my @out;
    for my $file (keys %$watched) {
        my $new_times = $self->_get_file_times($file);
        my $old_times = $self->{+TIMES}->{$file} //= $new_times;

        next if $old_times->[0] == $new_times->[0] && $old_times->[1] == $new_times->[1];

        # Update so we do not reload twice for the same change
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

Test2::Harness::Reloader::Stat - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut


=pod

=cut POD NEEDS AUDIT

