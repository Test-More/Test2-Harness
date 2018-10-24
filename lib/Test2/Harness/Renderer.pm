package Test2::Harness::Renderer;
use strict;
use warnings;

our $VERSION = '0.001071';

use Carp qw/croak/;

use Test2::Harness::Util::HashBase qw/-settings -verbose -color/;

sub render_event { croak "$_[0] forgot to override 'render_event()'" }

sub finish { }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Renderer - Base class for Test2::Harness event renderers.

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
