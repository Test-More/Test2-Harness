package Test2::Harness2::Util::File::Value;
use strict;
use warnings;

our $VERSION = '2.000011';

use parent 'Test2::Harness2::Util::File';
use Object::HashBase;

sub init {
    my $self = shift;
    $self->SUPER::init();
    $self->{+DONE} = 1;
}

sub read {
    my $self = shift;
    my $out  = $self->SUPER::read(@_);
    chomp($out) if defined $out;
    return $out;
}

# Probably do not need readline on a file that has 1 value
sub read_line {
    my $self = shift;
    my $out  = $self->SUPER::read_line(@_);
    chomp($out) if defined $out;
    return $out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::File::Value - Utility class for a file that contains
exactly 1 value.

=head1 DESCRIPTION

Subclass of L<Test2::Harness2::Util::File> for files that store exactly
one value, with the trailing newline stripped from reads. C<done> is
set at construction time so partial-line reads in subclasses do not
hold back the value when the file lacks a final newline.

=head1 SYNOPSIS

    use Test2::Harness2::Util::File::Value;

    my $vf  = Test2::Harness2::Util::File::Value->new(name => 'path/to/file');
    my $val = $vf->read;

=head1 METHODS

=over 4

=item $val = $vf->read()

Read all contents from the file, C<chomp()> the result, and return it.

=item $val = $vf->read_line()

Read a single line from the file, C<chomp()> it, and return it. Will
return the content even if the file does not end with a newline.

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
