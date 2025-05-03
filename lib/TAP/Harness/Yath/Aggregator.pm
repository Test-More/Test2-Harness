package TAP::Harness::Yath::Aggregator;

use strict;
use warnings;

our $VERSION = '2.000005';

BEGIN {
    require Test::Harness;
    Test::Harness->VERSION(3.49);
}

use Test2::Harness::Util::HashBase qw{
    files_total
    files_failed
    files_passed

    asserts_total
    asserts_passed
    asserts_failed
};

sub has_errors { $_[0]->{+FILES_FAILED} || $_[0]->{+ASSERTS_FAILED} }

sub total  { $_[0]->{+ASSERTS_TOTAL} }
sub failed { $_[0]->{+ASSERTS_FAILED} }
sub passed { $_[0]->{+ASSERTS_PASSED} }

sub total_files  { $_[0]->{+FILES_TOTAL} }
sub failed_files { $_[0]->{+FILES_FAILED} }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

TAP::Harness::Yath::Aggregator - Aggregator for TAP::Harness::Yath.

=head1 DESCRIPTION

Implementation detail, not for general use.

=head1 SYNOPSIS

See L<TAP::Harness::Yath>.

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

