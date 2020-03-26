package Test2::Harness::UI::Controller;
use strict;
use warnings;

our $VERSION = '0.000028';

use Carp qw/croak/;

use Test2::Harness::UI::Response qw/error/;

use Test2::Harness::UI::Util::HashBase qw/-request -config/;

sub uses_session { 1 }

sub init {
    my $self = shift;

    croak "'request' is a required attribute" unless $self->{+REQUEST};
    croak "'config' is a required attribute"  unless $self->{+CONFIG};
}

sub title  { 'Test2-Harness-UI' }
sub handle { error(501) }

sub schema { $_[0]->{+CONFIG}->schema }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Controller

=head1 DESCRIPTION

=head1 SYNOPSIS

TODO

=head1 SOURCE

The source code repository for Test2-Harness-UI can be found at
F<http://github.com/Test-More/Test2-Harness-UI/>.

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
