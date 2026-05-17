package App::Yath2::Formatter::Txt;
use strict;
use warnings;

our $VERSION = '2.000013';

use parent 'App::Yath2::Formatter';

# Experimental: facet coverage will be extended in Stage 5.1 to match
# the full legacy Default renderer output. Until then this formatter
# handles only the assert and info facets. Renderers may use it for
# live output but should not persist its bytes as artifacts — hence
# produces_artifact returns 0.
sub produces_artifact { 0 }

# Convert a single event item to plain text. Only a minimal subset of
# facets is handled in this stage:
#
#   assert  — the assertion detail line
#   info    — each informational message line
#
# Items with no recognised facets produce an empty string.
sub convert_item {
    my ($self, $item) = @_;
    my $fd  = $item->{facet_data} or return '';
    my $out = '';

    if (my $a = $fd->{assert}) {
        $out .= ($a->{details} // '') . "\n";
    }

    if (my $i = $fd->{info}) {
        for my $line (@$i) {
            $out .= ($line->{details} // '') . "\n";
        }
    }

    return $out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Formatter::Txt - Plain-text event formatter (experimental)

=head1 DESCRIPTION

A plain-text formatter that converts harness events into human-readable
lines. Inherits from L<App::Yath2::Formatter>.

B<Experimental:> facet coverage is limited to C<assert> and C<info> in
this stage. Coverage will be extended in a later stage to match the full
output of the legacy Default renderer. Until that work is complete,
C<produces_artifact> returns C<0> — renderers may use this formatter for
live output but should not persist its bytes as log artifacts.

=head1 INTERFACE

=over 4

=item $bool = App::Yath2::Formatter::Txt->produces_artifact

Returns C<0>. This formatter is experimental and its output should not
be persisted as a log artifact until facet coverage is complete.

=item $bytes = $formatter->convert_item($item)

Convert a single event hashref to a plain-text byte string. The following
facets are handled:

=over 4

=item assert

Appends C<$facet-E<gt>{details}> followed by a newline.

=item info

For each element in the info array, appends C<$elem-E<gt>{details}>
followed by a newline.

=back

Items with no recognised facets produce an empty string.

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

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
