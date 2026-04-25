package Test2::Harness2::Collector::Preloaded;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use POSIX ();

use Test2::Harness2::Util::IPC qw/swap_io/;

use parent 'Test2::Harness2::Collector::Test';

use Object::HashBase qw{
    <test_file
    <stage
};

sub init {
    my $self = shift;

    croak "'test_file' is required" unless defined $self->{+TEST_FILE};

    # Trigger the collector's launch path; _launch_child_unix replaces
    # exec with goto::file so the forked child runs the test inline.
    $self->{+LAUNCH} //= $self->{+TEST_FILE};

    $self->SUPER::init();
}

sub _launch_child_unix {
    my $self = shift;
    my ($out_r, $out_w, $err_r, $err_w, $orig_stdout, $orig_stderr) = @_;

    my $test_file = $self->{+TEST_FILE};
    my $stage     = $self->{+STAGE};

    my $pid = fork() // die "Failed to fork preloaded test child: $!";

    if (!$pid) {
        # Child process: set up I/O, then run the test via goto::file
        $out_r->close();
        $err_r->close();

        swap_io(\*STDOUT, $out_w->wh);
        swap_io(\*STDERR, $err_w->wh);
        STDOUT->autoflush(1);
        STDERR->autoflush(1);

        close($orig_stdout);
        close($orig_stderr);

        POSIX::setpgid(0, 0) or warn "setpgid(0,0) failed: $!"
            if $self->{+NEW_PGROUP};

        my %env = $self->_child_env_overrides;
        $ENV{$_} = $env{$_} for keys %env;
        $ENV{T2_HARNESS_FORKED}  = 1;
        $ENV{T2_HARNESS_PRELOAD} = 1;

        $stage->do_post_fork() if $stage;

        if ($INC{'Test2/API.pm'}) {
            Test2::API::test2_stop_preload();
            Test2::API::test2_post_preload_reset();
            Test2::API::test2_enable_trace_stamps();
        }

        $0 = $test_file;

        $stage->do_pre_launch() if $stage;

        require goto::file;
        goto::file->import($test_file);

        # Execution of the test begins here (goto::file transfers control).
        # When the test exits, the process exits. Any code below is unreachable.
        POSIX::_exit(255);
    }

    # Parent (collector): restore STDOUT/STDERR
    open(STDOUT, '>&', $orig_stdout) or croak "Could not restore STDOUT: $!";
    open(STDERR, '>&', $orig_stderr) or croak "Could not restore STDERR: $!";

    return $pid;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Preloaded - Collector that runs tests from a
preloaded fork using C<goto::file>.

=head1 DESCRIPTION

Extends L<Test2::Harness2::Collector::Test> for the preload execution path.
Instead of C<exec>-ing the test script (which would discard the preloaded
C<%INC> state), this collector forks a child that uses L<goto::file> to swap
in the test script inline. The forked child inherits all preloaded modules
without needing a fresh C<require>.

=head1 ATTRIBUTES

=over 4

=item test_file (required)

Absolute path to the test script to execute.

=item stage (optional)

A L<Test2::Harness2::Preload::Stage> instance. When set, its
C<do_post_fork> and C<do_pre_launch> callbacks fire at the appropriate
points in the child process.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
