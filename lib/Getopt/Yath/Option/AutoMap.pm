package Getopt::Yath::Option::AutoMap;
use strict;
use warnings;

our $VERSION = '2.000005';

use parent 'Getopt::Yath::Option::Map';
use Test2::Harness::Util::HashBase;

sub allows_arg        { 1 }
sub requires_arg      { 0 }
sub allows_default    { 1 }
sub allows_autofill   { 1 }
sub requires_autofill { 1 }

sub default_long_examples  { ['', '=key=val'] }
sub default_short_examples { ['', 'key=val', '=key=val'] }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Getopt::Yath::Option::AutoMap - FIXME

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

