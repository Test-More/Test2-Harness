package Test2::Harness::Feeder;
use strict;
use warnings;

our $VERSION = '0.001080';

use Carp qw/confess/;

use Test2::Harness::Watcher();

use Test2::Harness::Util::HashBase;

sub poll { confess "poll() is not implemented for $_[0]" }

sub init {}

# Default, most feeders will be complete by nature.
sub complete { 1 }

# Most ignore this, some need it
sub job_completed { }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Feeder - Base class for event feeds.

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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
