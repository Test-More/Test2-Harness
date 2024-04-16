package Test2::Harness::UI::Schema::Result::LogFile;
use utf8;
use strict;
use warnings;

use Carp qw/confess/;
confess "You must first load a Test2::Harness::UI::Schema::NAME module"
    unless $Test2::Harness::UI::Schema::LOADED;

our $VERSION = '2.000000';

require "Test2/Harness/UI/Schema/${Test2::Harness::UI::Schema::LOADED}/LogFile.pm";
require "Test2/Harness/UI/Schema/Overlay/LogFile.pm";

with 'Test2::Harness::UI::Schema::Roles::Columns';

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Schema::Result::LogFile - Autogenerated result class for LogFile.

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
