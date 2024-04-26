package App::Yath::Options::Server;
use strict;
use warnings;

our $VERSION = '2.000000';

use Getopt::Yath;

option_group {group => 'server', prefix => 'server', category => "Server Options"} => sub {
    option url => (
        type => 'Scalar',
        alt => ['uri'],
        description => "Yath-UI url",
        long_examples  => [" http://my-yath-ui.com/..."],
    );
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Server - FIXME

=head1 DESCRIPTION

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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

