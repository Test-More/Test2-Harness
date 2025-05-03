package Test2::Harness::Collector::Auditor;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp qw/croak/;

use Test2::Harness::Util::HashBase;

sub init {}

sub audit { croak "'$_[0]' does not implement audit()" }
sub pass { croak "'$_[0]' does not implement pass()" }
sub fail { croak "'$_[0]' does not implement fail()" }
sub has_exit { croak "'$_[0]' does not implement has_exit()" }
sub has_plan { croak "'$_[0]' does not implement has_plan()" }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Collector::Auditor - FIXME

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

