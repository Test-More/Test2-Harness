package App::Yath::Options::Recent;
use strict;
use warnings;

our $VERSION = '2.000005';

use Getopt::Yath;

option_group {group => 'recent', prefix => 'recent', category => "Recent Options"} => sub {
    option max => (
        type => 'Scalar',
        long_examples => [' 10'],
        default => 10,
        description => 'Max number of recent runs to show',
    );
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Recent - Options for viewing recent activity.

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

