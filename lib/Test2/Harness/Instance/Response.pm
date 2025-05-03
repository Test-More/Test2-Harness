package Test2::Harness::Instance::Response;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp qw/croak/;

use parent 'Test2::Harness::Instance::Message';
use Test2::Harness::Util::HashBase qw{
    <response_id
    <response
    <api
};

sub init {
    my $self = shift;

    $self->SUPER::init();

    croak "'response_id' is a required attribute" unless $self->{+RESPONSE_ID};
    croak "'response' is a required attribute" unless exists $self->{+RESPONSE};
    croak "'api' is a required attribute" unless $self->{+API};
}

sub success {
    my $self = shift;
    return $self->{+API}->{success} ? 1 : 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Instance::Response - FIXME

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

