package Test2::Harness::Plugin;
use strict;
use warnings;

use feature 'state';
use Carp();

our $VERSION = '2.000005';

sub tick              { }
sub run_queued        { }
sub run_complete      { }
sub run_halted        { }
sub client_setup      { }
sub client_teardown   { }
sub client_finalize   { }
sub instance_setup    { }
sub instance_teardown { }
sub instance_finalize { }

sub TO_JSON { ref($_[0]) || "$_[0]" }

sub redirect_io { Carp::confess("redirect_io() is deprecated") }
sub shellcall   { Carp::confess("shellcall() is deprecated, use shell_call() instead, note that arguments have changed") }

sub insane_methods { qw/handle_event inject_run_data spawn_args setup teardown finalize finish/ }

sub sanity_checks {
    my $class = shift;

    for my $meth ($class->insane_methods) {
        next unless $class->can($meth);
        warn "Plugin '$class' implementes ${meth}\() which is no longer used, the module needs to be updated.\n";
    }
}

sub send_event {
    my $class = shift;

    state($SEND_EVENT, $SEND_EVENT_PID);

    $SEND_EVENT = undef unless $SEND_EVENT_PID && $$ == $SEND_EVENT_PID;

    unless ($SEND_EVENT) {
        require Test2::Harness::Collector::Child;
        local $@;
        $SEND_EVENT = eval { Test2::Harness::Collector::Child->send_event } or Carp::confess("Cannot send an event from here: $@");
        $SEND_EVENT_PID = $$;
    }

    return $SEND_EVENT->(@_);
}

sub shell_call {
    my $this = shift;
    my ($name, @cmd) = @_;

    Carp::croak("No name provided")    unless $name;
    Carp::croak("No command provided") unless @cmd && length($cmd[0]);

    require Test2::Harness::IPC::Util;
    my $pid = Test2::Harness::IPC::Util::start_collected_process(
        io_pipes     => $ENV{T2_HARNESS_PIPE_COUNT},
        command      => \@cmd,
        root_pid     => $$,
        type         => 'plugin',
        name         => $name,
        tag          => $name,
        setsid       => 0,
        forward_exit => 1,
    );

    local $? = 0;
    waitpid($pid, 0);
    return $?;
}

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Plugin - Base class for Test2::Harness plugins.

=head1 DESCRIPTION

This class holds the methods specific to L<Test2::Harness> which
is the backend. Most of the time you actually want to subclass
L<App::Yath::Plugin> which subclasses this class, and holds additional methods
that apply to yath (the UI layer).

=head1 SYNOPSIS

You probably want to subclass L<App::Yath::Plugin> instead. This class here
mainly exists to separate concerns, but is not something you should use
directly.

    package Test2::Harness::Plugin::MyPlugin;

    use parent 'Test2::Harness::Plugin';

    # ... Define methods

    1;

=head1 METHODS

=over 4

=item $plugin->munge_search($input, $default_search, $settings)

C<$input> is an arrayref of files and/or directories provided at the command
line.

C<$default_search> is an arrayref with the default files/directories pulled in
when nothing is specified at the command ine.

C<$settings> is an instance of L<Test2::Harness::Settings>

=item $undef_or_inst = $plugin->claim_file($path, $settings)

This is a chance for a plugin to claim a test file early, before Test2::Harness
takes care of it. If your plugin does not want to claim the file just return
undef. To claim the file return an instance of L<Test2::Harness::TestFile>
created with C<$path>.

=item $plugin->munge_files(\@tests, $settings)

This is an opportunity for your plugin to modify the data for any test file
that will be run. The first argument is an arrayref of
L<Test2::Harness::TestFile> objects.

=item $hashref = $plugin->duration_data($settings, $test_names)

If defined, this can return a hashref of duration data. This should return
undef if no duration data is provided. The first plugin listed that provides
duration data wins, no other plugins will be checked once duration data is
obtained.

Example duration data:

    {
        't/foo.t' => 'medium',
        't/bar.t' => 'short',
        't/baz.t' => 'long',
    }

=item $hashref_or_arrayref = $plugin->coverage_data(\@changed)

=item $hashref_or_arrayref = $plugin->coverage_data()

If defined, this can return a hashref of all coverage data, or an arrayref of
tests that cover the tests listed in @changed. This should return undef if no
coverage data is available. The first plugin to provide coverage data wins, no
other plugins will be checked once coverage data has been obtained.

Examples:

    [
        'foo.t',
        'bar.t',
        'baz.t',
    ]

    {
        'lib/Foo.pm' => [
            't/foo.t',
            't/integration.t',
        ],
        'lib/Bar.pm' => [
            't/bar.t',
            't/integration.t',
        ],
    }

=item $plugin->post_process_coverage_tests($settings, \@tests)

This is an opportunity for a plugin to do post-processing on the list of
coverage tests to run. This is mainly useful to remove duplicates if multiple
plugins add coverage data, or merging entries where applicable. This will be
called after all plugins have generated their coverage test list.

Plugins may implement this without implementing coverage_data(), making this
useful if you want to use a pre-existing coverage module and want to do
post-processing on what it provides.

=item $plugin->setup($settings)

This is a callback that lets you run setup logic when the runner starts. Note
that in a persistent runner this is run once on startup, it is not run for each
C<run> command against the persistent runner.

=item $plugin->teardown($settings)

This is a callback that lets you run teardown logic when the runner stops. Note
that in a persistent runner this is run once on termination, it is not run for
each C<run> command against the persistent runner.

=item @files = $plugin->changed_files($settings)

Get a list of files that have changed. Plugins are free to define what
"changed" means. This may be used by the finder to determine what tests to run
based on coverage data collected in previous runs.

Note that data from all changed_files() calls from all plugins will be merged.

=item ($type, $value) = $plugin->changed_diff($settings)

Generate a diff that can be used to calculate changed files/subs for which to
run tests. Unlike changed_files(), only 1 diff will be used, first plugin
listed that returns one wins. This is not run at all if a diff is provided via
--changed-diff.

Diffs must be in the same format as this git command:

    git diff -U1000000 -W --minimal BASE_BRANCH_OR_COMMIT

Some other diff formats may work by chance, but they are not dirfectly
supported. In the future other diff formats may be directly supported, but not
yet.

The following return sets are allowed:

=over 4

=item file => string

Path to a diff file

=item diff => string

In memory diff as a single string

=item lines => \@lines

Diff where each line is a seperate string in an arrayref.

=item line_sub => sub { ... }

Sub that returns one line per call and undef when there are no more lines

=item handle => $FH

A filehandle to the diff

=back

=item $exit = $plugin->shell_call($name, $cmd)

=item $exit = $plugin->shell_call($name, @cmd)

This is essentially the same as C<system()> except that STDERR and STDOUT are
redirected to files that the yath collector will pick up so that any output
from the command will be seen as events and will be part of the yath log. If no
workspace is available this will not redirect IO and it will be identical to
calling C<system()>.

This is particularily useful in C<setup()> and C<teardown()> when running
external commands, specially any that daemonize and continue to produce output
after the setup/teardown method has completed.

$name is required because it will be used for filenames, and will be used as
the output tag (best to limit it to 8 characters).

=item $plugin->TO_JSON

This is here as a bare minimum serialization method. It returns the plugin
class name.

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

