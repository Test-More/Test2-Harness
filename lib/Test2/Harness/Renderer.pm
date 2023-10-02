package Test2::Harness::Renderer;
use strict;
use warnings;

our $VERSION = '1.000155';

use Carp qw/croak/;

use Test2::Harness::Util::HashBase qw/-settings -verbose -progress -color -command_class/;

sub render_event { croak "$_[0] forgot to override 'render_event()'" }

sub step {}

sub finish { }

sub signal { }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Renderer - Base class for Test2::Harness event renderers.

=head1 DESCRIPTION

=head1 ATTRIBUTES

These are set at construction time and cannot be changed.

=over 4

=item $settings = $renderer->settings

Get the L<Test2::Harness::Settings> reference.

=item $int = $renderer->verbose

Get the verbosity level.

=item $bool = $renderer->progress

True if progress indicators should be shown.

=item $bool = $renderer->color

True if color should be used.

=back

=head1 METHODS

=over 4

=item $renderer->render_event($event)

Called for every event. Return is ignored.

=item $renderer->finish(%ARGS)

Called once after testing is done.

C<%ARGS>:

=item $renderer->signal($signal)

Called when the rendering process receives a signal. This is your chance to do
any cleanup or report the signal. This is not an event, you can ignore it. Do
not exit or throw any exceptions here please.

=over 4

=item settings => $settings

Get the L<Test2::Harness::Settings> reference.

=item pass => $bool

True if tests passed.

=item tests_seen => $int

Number of test files seen.

=item asserts_seen => $int

Number of assertions made.

=item final_data => $final_data

The final_data looks like this, note that some data may not be present if it is
not applicable. The data structure can be as simple as
C<< { pass => $bool } >>.

    {
        pass => $pass,    # boolean, did the test run pass or fail?

        failed => [       # Jobs that failed, and did not pass on a retry
            [$job_id1, $file1],    # Failing job 1
            [$job_id2, $file2],    # Failing job 2
            ...
        ],
        retried => [               # Jobs that failed and were retried
            [$job_id1, $times_run1, $file1, $passed_eventually1],    # Passed_eventually is a boolean
            [$job_id2, $times_run2, $file2, $passed_eventually2],
            ...
        ],
        hatled => [                                                  # Jobs that caused the entire test suite to halt
            [$job_id1, $file1, $halt_reason1],                       # halt_reason is a human readible string
            [$job_id2, $file2, $halt_reason2],
        ],
    }

=back

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
