package App::Yath2::Options::Scheduler;
use strict;
use warnings;

use Test2::Harness2::Util qw/fqmod/;

our $VERSION = '2.000011';

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Tests',
);

option_group {group => 'scheduler', category => 'Scheduler Options'} => sub {
    # TODO: Stage 6 — activate --scheduler when alternative schedulers ship
    # option class => (
    #     name    => 'scheduler',
    #     field   => 'class',
    #     type    => 'Scalar',
    #     default => 'Test2::Harness2::Scheduler',
    #
    #     mod_adds_options => 1,
    #     long_examples    => [' MyScheduler', ' +Test2::Harness2::MyScheduler'],
    #     description      => 'Specify what Scheduler subclass to use. Use the "+" prefix to specify a fully qualified namespace, otherwise Test2::Harness2::Scheduler::XXX namespace is assumed.',
    #
    #     normalize => sub { fqmod($_[0], 'Test2::Harness2::Scheduler') },
    # );
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Scheduler - Scheduler options for Yath.

=head1 DESCRIPTION

This is where command line options for the runner are defined.

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
