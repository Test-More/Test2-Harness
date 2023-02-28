package Test2::EventFacet::Binary;
use strict;
use warnings;

our $VERSION = '0.000136';

sub is_list { 1 }

BEGIN { require Test2::EventFacet; our @ISA = qw(Test2::EventFacet) }
use Test2::Util::HashBase qw{-data -filename -is_image};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::EventFacet::Binary - Event for a binary file

=head1 DESCRIPTION

Binary files attached to log

=head1 FIELDS

=over 4

=item $string_or_structure = $binary->{details}

=item $string_or_structure = $binary->details()

Human readible description of the binary

=item $binary_data = $binary->{data}

=item $binary_data = $binary->data()

This should be Base64 encoded binary data.

=item $string = $binary->{filename}

=item $string = $binary->filename()

Filename

=item $bool = $binary->{is_image}

=item $bool = $binary->is_image()

True if the binary file is an image file.

=back

=head1 SOURCE

The source code repository for Test2-Harness-UI can be found at
F<https://github.com/Test-More/Test2-Harness-UI/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2022 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
