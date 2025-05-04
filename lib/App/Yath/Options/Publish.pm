package App::Yath::Options::Publish;
use strict;
use warnings;

our $VERSION = '2.000006';

use Getopt::Yath;

option_group {group => 'publish', prefix => 'publish', category => "Publish Options"} => sub {
    option mode => (
        type => 'Scalar',
        default => 'qvfd',
        description => "Set the upload mode (default 'qvfd')",
        long_examples => [
            ' summary',
            ' qvf',
            ' qvfd',
            ' complete',
        ],
    );

    option flush_interval => (
        type => 'Scalar',
        long_examples => [' 2', ' 1.5'],
        description => 'When buffering DB writes, force a flush when an event is recieved at least N seconds after the last flush.',
    );

    option buffer_size => (
        type => 'Scalar',
        long_examples => [ ' 100' ],
        description => 'Maximum number of events, coverage, or reporting items to buffer before flushing them (each has its own buffer of this size, and each job has its own event buffer of this size)',
        default => 100,
    );

    option retry => (
        type => 'Count',
        description => "How many times to retry an operation before giving up",
        default => 0,
    );

    option force => (
        type => 'Bool',
        description => 'If the run has already been published, override it. (Delete it, and publish again)',
        default => 0,
    );

    option user => (
        type => 'Scalar',
        description => "User to publish results as",
        default => sub { $ENV{USER} }
    );
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Publish - FIXME

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

