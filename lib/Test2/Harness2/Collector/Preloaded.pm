package Test2::Harness2::Collector::Preloaded;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use POSIX ();

use Long::Jump qw/longjump havejump/;

use Test2::Harness2::Collector ();

# ---------------------------------------------------------------------------
# Class method: launch
#
# Drives the stage-side fork+collector+fork+execute sequence documented in
# Test2::Harness2::Preloader. Called from inside a
# Test2::Harness2::Preloader::Stage service process when a launch_test
# request arrives:
#
#   1. Build a Test2::Harness2::Collector via interpose(), which forks the
#      stage-service process into a (collector, test-child) pair and wires
#      mixed-mode Atomic::Pipes between them. The collector parent never
#      returns -- it runs the Collector's read loop and exits when the test
#      finishes.
#   2. In the test-child, run the stage's post_fork and pre_launch
#      callbacks -- STDOUT/STDERR are now the collector's read pipes, so
#      anything the callbacks emit flows through the normal parser chain.
#   3. longjump the test payload back to the base preloader's setjump
#      landing. The landing calls goto::file to hand control to the
#      requested test file with an effectively empty Perl stack.
#
# Required args:
#   stage_obj   Test2::Harness2::Preload::Stage
#   test_file   absolute path to the test .t file
#   jump_label  the Long::Jump label established by the base preloader
#   ipcm_info   IPC::Manager connection info (forwarded to Collector)
#
# Optional args (all forwarded to Collector::interpose where relevant):
#   loggers     [ [class, %args], ..., $blessed_instance, ... ]
#   auditor     class name or blessed instance
#   parser      class name (default: IOParser::Stream)
#   run_id / job_id / job_try
#   env         \%env to expose to the test after the jump
#   argv        \@argv to set for the test after the jump
# ---------------------------------------------------------------------------
sub launch {
    my $class = shift;
    my %p = @_;

    my $stage      = $p{stage_obj}  or croak "'stage_obj' is required";
    my $test_file  = $p{test_file}  or croak "'test_file' is required";
    my $jump_label = $p{jump_label} or croak "'jump_label' is required";
    my $ipcm_info  = $p{ipcm_info}  or croak "'ipcm_info' is required";

    croak "No active setjump named '$jump_label'; is the base preloader running?"
        unless havejump($jump_label);

    my %collector_args = (
        ipcm_info => $ipcm_info,
        parser    => $p{parser} // 'Test2::Harness2::Collector::Parser::IOParser::Stream',
        loggers   => $p{loggers} // [],
        (defined $p{auditor} ? (auditor => $p{auditor}) : ()),
        (defined $p{run_id}  ? (run_id  => $p{run_id})  : ()),
        (defined $p{job_id}  ? (job_id  => $p{job_id})  : ()),
        (defined $p{job_try} ? (job_try => $p{job_try}) : ()),
    );

    # interpose forks internally:
    #   parent -> becomes the collector, runs read loop, exits (never returns)
    #   child  -> returns here with STDOUT/STDERR rewired to the collector
    Test2::Harness2::Collector->interpose(%collector_args);

    # ----- forked test child from here on -----

    # Run callback lifecycle. Errors are warned, not fatal: a broken hook
    # should not deadlock the test; the harness will see whatever the test
    # emits and can act on it.
    unless (eval { $stage->do_post_fork({test_file => $test_file, %p}); 1 }) {
        warn "$$ $0 - post_fork failed in stage '" . $stage->name . "': $@";
    }

    unless (eval { $stage->do_pre_launch({test_file => $test_file, %p}); 1 }) {
        warn "$$ $0 - pre_launch failed in stage '" . $stage->name . "': $@";
    }

    # Hand the test payload up to the base preloader's setjump landing.
    # Long::Jump unwinds the stack back to the top-level setjump expression
    # in the bootstrap script; _post_jump_launch then calls goto::file.
    longjump($jump_label => {
        kind      => 'launch_test',
        test_file => $test_file,
        env       => $p{env},
        argv      => $p{argv},
        stage     => $stage->name,
    });

    # longjump does not return; this is a belt-and-suspenders exit.
    POSIX::_exit(254);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Preloaded - Launch a test from inside a preload
stage service by attaching a collector and longjumping to the base
preloader's stack-zero landing.

=head1 DESCRIPTION

Wraps the "fork + collector + fork + execute" sequence used by a stage
service to run a test under the preloader. Call L</launch> from the stage
service's C<launch_test> request handler; the call never returns in the
calling process, but the stage service's parent is the forked collector
and continues to serve other requests.

Under the hood this leans on L<Test2::Harness2::Collector/interpose>: that
method creates the mixed-mode pipes, forks, promotes the parent of the
fork into the collector, and returns to the caller in the child with
STDOUT/STDERR rewired to the pipes. This class adds the stage-callback
invocation and the L<Long::Jump> to the preloader's root.

=head1 METHOD

=over 4

=item Test2::Harness2::Collector::Preloaded->launch(%args)

Required arguments:

=over 4

=item stage_obj    L<Test2::Harness2::Preload::Stage> for the stage

=item test_file    absolute path to the test file

=item jump_label   name of the setjump established by the base preloader

=item ipcm_info    L<IPC::Manager> connection info for loggers

=back

Optional arguments:

=over 4

=item loggers / auditor / parser

Passed to L<Test2::Harness2::Collector>. Parser defaults to
C<IOParser::Stream> which recognises Stream2 JSON bursts.

=item run_id / job_id / job_try

Identifiers included on every event the collector produces.

=item env / argv

Applied to the test process after the jump lands.

=back

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
