package App::Yath::Plugin;
use strict;
use warnings;

our $VERSION = '1.000155';

use parent 'Test2::Harness::Plugin';

# We do not want this defined by default, but it should be documented
#sub handle_event {}
#sub sort_files {}
#sub sort_files_2 {}

sub finish {}

sub finalize {}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Plugin - Base class for yath plugins

=head1 DESCRIPTION

This is a base class for yath plugins. Note this class also subclasses
L<Test2::Harness::Plugin>.

This class holds the methods specific to yath, which is the UI layer.
L<Test2::Harness::Plugin> holds the methods specific to L<Test2::Harness> which
is the backend.

=head1 SYNOPSIS

    package App::Yath::Plugin::MyPlugin;

    use parent 'App::Yath::Plugin';

    # ... Define methods

    1;


Then to use it at the command line:

    $ yath -pMyPlugin ...

=head1 NOTE ON INSTANCE VS CLASS

None of the plugin base classes provide a C<new()> method. By default plugins
are not instantiated and only the plugin package name is passed around. All
methods are then called on the class.

If you want your plugin to be instantiated as an object you need only define a
C<new()> method. If this method is defined yath will call it and create an
instance. The instance created will then be used when calling all the methods.

To pass arguments to the constructor you can use
C<yath -pYourPlugin=arg1,arg2,arg3...>. Your plugin can also define options
using L<App::Yath::Options> which will be dropped into the C<$settings> that
get passed around.

=head1 METHODS

B<Note:> See L<Test2::Harness::Plugin> for additional method you can implement/override

=over 4

=item $plugin->handle_event($event, $settings)

Called for every single event that yath sees. Note that this method is not
defined by default for performance reasons, however it will be called if you
define it.

=item @sorted = $plugin->sort_files_2(settings => $settings, files => \@unsorted)

This gives your plugin a chance to sort the files before they are added to the
queue. Other things are done later to re-order the files optimally based on
length or category, so this sort is just for initial job numbering, and to
define a base order before optimization takes place.

All files to sort will be instances of L<Test2::Harness::TestFile>.

This method is normally left undefined, but will be called if you define it.

If this is present then C<sort_files()> will be ignored.

=item @sorted = $plugin->sort_files(@unsorted)

B<DEPRECATED> Use C<sort_files_2()> instead.

This gives your plugin a chance to sort the files before they are added to the
queue. Other things are done later to re-order the files optimally based on
length or category, so this sort is just for initial job numbering, and to
define a base order before optimization takes place.

All files to sort will be instances of L<Test2::Harness::TestFile>.

This method is normally left undefined, but will be called if you define it.

=item $plugin->finish(%args)

This is what arguments are recieved:

    (
        settings     => $settings,                      # The settings
        final_data   => $final_data,                    # See below
        pass         => $pass ? 1 : 0,                  # Always a 0 or 1
        tests_seen   => $self->{+TESTS_SEEN} // 0,      # Integer 0 or greater
        asserts_seen => $self->{+ASSERTS_SEEN} // 0,    # Integer 0 or greater
    )

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

=item $plugin->finalize($settings)

This is called as late as possible before exit. This is mainly useful for
outputting messages such as "Extra log file written to ..." which are best put
at the end of output.

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
