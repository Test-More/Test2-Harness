package App::Yath2::Options::IPCAll;
use strict;
use warnings;
use feature 'state';

our $VERSION = '2.000011';

use Getopt::Yath;
include_options(
    'App::Yath2::Options::IPC',
);

option_group {group => 'ipc', category => 'IPC Options'} => sub {
    # TODO: Stage 6 — activate --ipc-allow-non-daemon when non-daemon flows ship
    # option allow_non_daemon => (
    #     name => 'ipc-allow-non-daemon',
    #     type => 'Bool',
    #     default => 1,
    #     description => 'Normally yath commands will only connect to daemons, but some like "resources" can work on non-daemon instances',
    # );
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::IPCAll - FIXME

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

