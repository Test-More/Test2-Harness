package Test2::Harness::Util::File::Value;
use strict;
use warnings;

our $VERSION = '0.001077';

use parent 'Test2::Harness::Util::File';
use Test2::Harness::Util::HashBase;

sub init {
    my $self = shift;
    $self->{+DONE} = 1;
}

sub read {
    my $self = shift;
    my $out = $self->SUPER::read(@_);
    chomp($out) if defined $out;
    return $out;
}

sub read_line {
    my $self = shift;
    my $out = $self->SUPER::read_line(@_);
    chomp($out) if defined $out;
    return $out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Util::File::Value - Utility class for a file that contains
exactly 1 value.

=head1 DESCRIPTION

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
