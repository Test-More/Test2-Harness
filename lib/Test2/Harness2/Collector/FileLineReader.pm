package Test2::Harness2::Collector::FileLineReader;
use strict;
use warnings;

our $VERSION = '2.000011';

sub new {
    my ($class, $fh) = @_;
    return bless {fh => $fh, eof => 0}, $class;
}

sub read_lines {
    my $self = shift;
    my $fh   = $self->{fh};

    return () if $self->{eof};

    my @lines;
    while (defined(my $line = <$fh>)) {
        chomp $line;
        push @lines => [line => $line];
    }

    # If readline returned undef we hit EOF
    if (eof($fh)) {
        $self->{eof} = 1;
        push @lines => undef;
    }

    return @lines;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::FileLineReader - Thin line-reader shim for regular file handles.

=head1 DESCRIPTION

Lets regular file handles be read with the same interface the collector uses
for L<Atomic::Pipe> handles. C<read_lines> returns a list of C<[line =E<gt>
$data]> tuples for each line currently available on the handle, and appends
C<undef> once EOF has been reached so callers can detect the end of stream.

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

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
