package Test2::Harness::Util::File::Stream;
use strict;
use warnings;

our $VERSION = '0.001001';

use Carp qw/croak/;
use Fcntl qw/LOCK_EX LOCK_UN SEEK_SET/;

use parent 'Test2::Harness::Util::File';
use Test2::Harness::Util::HashBase qw/use_write_lock/;

sub poll_with_index {
    my $self = shift;
    my %params = @_;

    my $max = delete $params{max} || 0;

    my $pos = $params{from};
    $pos = $self->{+LINE_POS} ||= 0 unless defined $pos;

    my @out;
    while (!$max || @out < $max) {
        my ($spos, $epos, $line) = $self->read_line(%params, from => $pos);
        last unless defined $line;

        $self->{+LINE_POS} = $epos unless $params{peek} || defined $params{from};
        push @out => [$spos, $epos, $line];
        $pos = $epos;
    }

    return @out;
}

sub read {
    my $self = shift;

    return $self->poll(from => 0);
}

sub poll {
    my $self = shift;
    my @lines = $self->poll_with_index(@_);
    return map { $_->[-1] } @lines;
}

sub write {
    my $self = shift;

    my $name = $self->{+NAME};

    my $fh = $self->open_file('>>');

    flock($fh, LOCK_EX) or die "Could not lock file '$name': $!"
        if $self->{+USE_WRITE_LOCK};

    print $fh $self->encode($_) for @_;
    $fh->flush;

    flock($fh, LOCK_UN) or die "Could not unlock file '$name': $!"
        if $self->{+USE_WRITE_LOCK};

    close($fh) or die "Could not clone file '$name': $!";

    return @_;
}

sub seek {
    my $self = shift;
    my ($pos) = @_;

    my $fh   = $self->fh;
    my $name = $self->{+NAME};

    seek($fh, $pos, SEEK_SET) or die "Could not seek to position $pos in file '$name': $!";
    $self->{+LINE_POS} = $pos;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Util::File::Stream - Utility class for manipulating a file that
serves as an output stream.

=head1 DESCRIPTION

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
