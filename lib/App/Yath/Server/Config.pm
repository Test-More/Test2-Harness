package App::Yath::Server::Config;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Util qw/get_tid pkg_to_file/;

use Carp qw/croak/;

use Test2::Harness::Util::HashBase qw{
    -single_user -single_run -no_upload
    -show_user
    -email
};

sub init {
    my $self = shift;

    $self->{+SHOW_USER} //= 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Server::Config - UI configuration

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

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
