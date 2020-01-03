package App::Yath::Plugin;
use strict;
use warnings;

our $VERSION = '1.000000';

use parent 'Test2::Harness::Plugin';

# We do not want this defined by default, but it should be documented
#sub handle_event {}
#sub sort_files {}

sub finish {}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Plugin - Base class for yath plugins

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
