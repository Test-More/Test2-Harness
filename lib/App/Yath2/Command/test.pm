package App::Yath2::Command::test;
use v5.38;

our $VERSION = '2.000000';

use parent 'App::Yath2::Command';

use Time::HiRes ();
use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness2;

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::test - Run test files through a fresh harness

=head1 DESCRIPTION

Creates a temporary SQLite harness database, runs the given test files
through the harness, and reports C<PASS> or C<FAIL> per job. Returns exit
code 0 when all tests pass, 1 otherwise.

=head1 SYNOPSIS

    yath test t/foo.t t/bar.t

=cut

=head1 PUBLIC METHODS

=over 4

=item $str = $class->summary

One-line summary of this command.

=cut

sub summary ($class) { 'Run test files through a fresh harness' }

=item $str = $class->description

Longer description of this command.

=cut

sub description ($class) { 'Create a SQLite harness database, run the given test files one at a time, and report pass/fail per job.' }

=item $exit = $self->run

Execute the test command. Creates a temporary SQLite database, starts a
runner, queues the supplied files as a single run, waits for completion,
then prints C<PASS> / C<FAIL> per job and returns 0 (all pass) or 1 (any
fail).

=back

=cut

sub run ($self) {
    my @files = @{$self->argv // []};
    unless (@files) {
        print "No test files given.\n";
        return 1;
    }

    my $db_path = './yath-' . gen_uuid() . '.sqlite';
    my $h       = Test2::Harness2->new(db_path => $db_path);
    $h->initialize;
    my $con = $h->connection;

    my $runner_uuid = $h->start_runner;
    my $run_uuid    = $h->queue_run(runner_uuid => $runner_uuid, files => \@files);

    $h->set_runner_mode($runner_uuid, 'stop');

    # Part 1: poll until the run stops. No timeout yet -- a runner that dies
    # before setting run.stopped would hang here; a deadline comes later.
    my $run;
    while (1) {
        $run = $con->handle('run')->by_id($run_uuid);
        last if $run && defined $run->field('stopped');
        Time::HiRes::sleep(0.1);
    }

    my $exit = 0;
    my @jobs = $con->handle('job', where => {run_uuid => $run_uuid})->all;
    for my $job (@jobs) {
        my $file   = $con->handle('test_file')->by_id($job->field('test_file_id'))->field('test_file');
        my $passed = $job->field('passed');
        if ($passed) {
            print "PASS  $file\n";
        }
        else {
            print "FAIL  $file\n";
            $exit = 1;
        }
    }

    $h->finalize_run($run_uuid);
    return $exit;
}

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
