package Test2::Harness::Plugin;
use strict;
use warnings;

our $VERSION = '1.000038';

# Document, but do not implement
#sub changed_files {}

sub munge_search {}

sub claim_file {}

sub munge_files {}

sub inject_run_data {}

sub setup {}

sub teardown {}

sub TO_JSON { ref($_[0]) || "$_[0]" }

sub redirect_io {
    my $this = shift;
    my ($settings, $name) = @_;

    my @caller = caller();
    my $at = "at $caller[1] line $caller[2].\n";
    die "Invalid settings ($settings) $at" unless $settings && ref($settings) eq 'Test2::Harness::Settings';
    die "No name provided $at"             unless $name;
    die "This cannot be used without a workspace $at" unless $settings->check_prefix('workspace');

    require File::Spec;
    require Test2::Harness::Util::IPC;

    my $dir = $settings->workspace->workdir;
    my $aux = File::Spec->catdir($dir, 'aux_logs');
    mkdir($aux) unless -d $aux;

    Test2::Harness::Util::IPC::swap_io(\*STDOUT, File::Spec->catfile($aux, "${name}-STDOUT.log"));
    Test2::Harness::Util::IPC::swap_io(\*STDERR, File::Spec->catfile($aux, "${name}-STDERR.log"));

    return;
}

sub shellcall {
    my $this = shift;
    my ($settings, $name, @cmd) = @_;

    require POSIX;

    my @caller = caller();
    my $at = "at $caller[1] line $caller[2].\n";
    die "Invalid settings ($settings) $at" unless $settings && ref($settings) eq 'Test2::Harness::Settings';
    die "No name provided $at" unless $name;
    die "No command provided $at" unless @cmd && length($cmd[0]);

    my $pid = fork // die "Could not fork: $!";
    if ($pid) {
        waitpid($pid, 0);
        return $?;
    }
    else {
        local $@;

        eval {
            if ($settings->check_prefix('workspace')) {
                $this->redirect_io($settings, $name);
            }
            exec(@cmd) if @cmd > 1;
            exec($cmd[0]);
        };

        chomp(my $err = $@ // "unknown error");

        warn "Could not run command ($@) $at";
        POSIX::_exit(1);
    }
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

=item $plugin->inject_run_data(meta => $meta, fields => $fields, run => $run)

This is a callback that lets your plugin add meta-data or custom fields to the
run event. The meta-data and fields are available in the event log, and are
particularily useful to L<App::Yath::UI>.

    sub inject_run_data {
        my $class  = shift;
        my %params = @_;

        my $meta   = $params{meta};
        my $fields = $params{fields};

        # Meta-data is a hash, each plugin should define its own key, and put
        # data under that key
        $meta->{MyPlugin}->{stuff} = "Stuff!";

        # Fields is an array of fields that a UI might want to display when showing the run.
        push @$fields => {name => 'MyPlugin', details => "Human Friendly Stuff", raw => "Less human friendly stuff", data => $all_the_stuff};

        return;
    }

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

=item $exit = $plugin->shellcall($settings, $name, $cmd)

=item $exit = $plugin->shellcall($settings, $name, @cmd)

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

=item $plugin->redirect_io($settings, $name)

B<WARNING:> This must NEVER be called in a primary yath process. Only use this
in forked processes that you control. If this is used in a main process it
could hide ALL output.

This will redirect STDERR and STDOUT to files that will be picked up by the
yath collector so that any output appears as proper yath events and will be
included in the yath log.

$name is required because it will be used for filenames, and will be used as
the output tag (best to limit it to 8 characters).

=item $plugin->TO_JSON

This is here as a bare minimum serialization method. It returns the plugin
class name.

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
