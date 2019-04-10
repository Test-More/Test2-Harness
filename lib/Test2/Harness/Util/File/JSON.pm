package Test2::Harness::Util::File::JSON;
use strict;
use warnings;

our $VERSION = '0.001074';

use Carp qw/croak/;
use Test2::Harness::Util::JSON qw/encode_json decode_json encode_pretty_json/;

use parent 'Test2::Harness::Util::File';
use Test2::Harness::Util::HashBase qw/pretty/;

sub decode { shift; decode_json(@_) }
sub encode { shift->pretty ? encode_pretty_json(@_) : encode_json(@_) }

sub reset { croak "line reading is disabled for json files" }
sub read_line  { croak "line reading is disabled for json files" }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Util::File::JSON - Utility class for a JSON file.

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
