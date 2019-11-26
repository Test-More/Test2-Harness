package Test2::Harness::Runner::Constants;
use strict;
use warnings;

our $VERSION = '1.000000';

use Importer Importer => 'import';

our @EXPORT = qw/CATEGORIES DURATIONS/;

use constant CATEGORIES => {general => 1, isolation => 1, immiscible => 1};
use constant DURATIONS  => {long    => 1, medium    => 1, short      => 1};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Constants - Constants shared between multiple runner
modules.

=head1 DESCRIPTION

B<PLEASE NOTE:> Test2::Harness is still experimental, it can all change at any
time. Documentation and tests have not been written yet!

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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
