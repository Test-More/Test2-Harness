package App::Yath::Resource;
use strict;
use warnings;

our $VERSION = '2.000002';

use Carp qw/croak/;

use parent 'Test2::Harness::Resource';
use Test2::Harness::Util::HashBase qw{
    <settings
};

sub init {
    my $self = shift;
    $self->SUPER::init();

    croak "'settings' is a required attribute" unless $self->{+SETTINGS};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Resource - FIXME

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

