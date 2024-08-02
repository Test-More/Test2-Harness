package App::Yath::Schema::Overlay::Resource;
our $VERSION = '2.000004';

package
    App::Yath::Schema::Result::Resource;
use utf8;
use strict;
use warnings;

use Carp qw/confess/;
confess "You must first load a App::Yath::Schema::NAME module"
    unless $App::Yath::Schema::LOADED;

__PACKAGE__->inflate_column(
    data => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('data', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('data', {}),
    },
);


1;
__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::Overlay::Resource - Overlay for Resource result class.

=head1 DESCRIPTION

This is where custom (not autogenerated) code for the Resource result class lives.

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

