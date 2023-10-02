package Test2::Harness::Runner::Preloader::Stage;
use strict;
use warnings;

our $VERSION = '1.000155';

use parent 'Test2::Harness::IPC::Process';
use Test2::Harness::Util::HashBase qw{ <name eager };

sub category { $_[0]->{+CATEGORY} //= 'stage' }

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Preloader::Stage - Representation of a persistent stage process.

=head1 DESCRIPTION

This module is responsible for preloading libraries for a specific stage before
running tests. This entire module is considered an "Implementation Detail".
Please do not rely on it always staying the same, or even existing in the
future. Do not use this directly.

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
