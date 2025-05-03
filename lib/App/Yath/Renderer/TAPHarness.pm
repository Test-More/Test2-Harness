package App::Yath::Renderer::TAPHarness;
use strict;
use warnings;

our $VERSION = '2.000005';

use parent 'App::Yath::Renderer';
use Test2::Harness::Util::HashBase;

sub render_event {}

sub finish {
    my $self = shift;
    my ($auditor) = @_;

    $TAP::Harness::Yath::SUMMARY = $auditor->summary;
}

1;

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Renderer::TAPHarness - Let yath run tests via cpanm and Makefile.PL

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

