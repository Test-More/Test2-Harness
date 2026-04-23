package App::Yath2::Command::test;
use strict;
use warnings;

our $VERSION = '2.000011';

use Object::HashBase qw{
    <settings
    <args
    <env_vars
    <option_state
    <plugins
};

use File::Spec();
use Carp qw/croak/;
use Time::HiRes qw/sleep/;

use Test2::Harness2();
use Test2::Harness2::TestFile();
use Test2::Harness2::Resource::JobCount();

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Workspace',
    'App::Yath2::Options::Yath',
);

use Role::Tiny::With;
with 'App::Yath2::Role::Command';

sub args_include_tests { 1 }
sub group              { 'test' }
sub summary            { 'Run a list of test files' }

sub description {
    return <<"    EOT";
Minimal test runner. Pass a list of test files; they are executed via a
Test2::Harness2 child service with 16-slot job concurrency. Exits 0 if every
test passed, non-zero otherwise. The pass/fail verdict is retrieved from the
harness service via IPC -- log files are not consulted.
    EOT
}

sub run {
    my $self = shift;

    # Autoflush both streams so any print reaches an interactive user
    # or a CI-captured log immediately instead of sitting in Perl's
    # default block buffer until the process exits.
    local $| = 1;
    STDERR->autoflush(1);

    my $settings = $self->{+SETTINGS};
    my $args     = $self->{+ARGS} // [];

    die "No test files supplied.\nUsage: yath test FILE [FILE ...]\n"
        unless @$args;

    my @files;
    for my $file (@$args) {
        die "Not a readable test file: $file\n" unless -f $file && -r _;
        push @files => Test2::Harness2::TestFile->new(file => $file);
    }

    my $workdir = $settings->workspace->workdir;

    my $spawn = Test2::Harness2->spawn(
        workdir   => $workdir,
        resources => [Test2::Harness2::Resource::JobCount->new(slots => 16)],
    );

    my $queued = $spawn->queue_test_run(files => \@files);
    die "Could not queue run: " . ($queued->{error} // '(no error)') . "\n"
        unless $queued->{ok};
    my $run_id = $queued->{run_id};

    # Poll the harness's run_results handler until the run completes.
    # The handler returns state => 'running' while there is still work
    # in the queue and state => 'complete' with the aggregate pass
    # verdict once run_state_update has observed the final mutation.
    #
    # Bounded deadline (default 15 min, override via YATH_TEST_TIMEOUT):
    # without a cap, an unresponsive harness would spin the loop until
    # the caller's wall-clock limit killed the process with no
    # diagnostics.
    my $timeout  = $ENV{YATH_TEST_TIMEOUT} // 900;
    my $deadline = time + $timeout;

    # Shapes of "harness peer is gone" from
    # IPC::Manager::Service::Handle::sync_request at shutdown:
    # in-flight race against service exit, or a post-close send to
    # a stale client registry. Either one around finish()/run_results
    # is an expected end-of-life race; any other error propagates.
    my $service_gone_re = qr/peer .* went away|is not a valid message recipient/;

    my $final;
    my $service_gone;
    while (time < $deadline) {
        my $resp = eval { $spawn->run_results(run_id => $run_id) };
        my $err  = $@;
        if (!defined $resp) {
            die $err unless $err =~ $service_gone_re;
            $service_gone = 1;
            last;
        }
        die "run_results rejected: " . ($resp->{error} // '(no error)') . "\n"
            unless $resp->{ok};

        if (($resp->{state} // '') eq 'complete') {
            $final = $resp;
            last;
        }

        sleep(0.05);
    }

    unless ($final || $service_gone) {
        # Deadline exceeded. Do NOT call $spawn->status or
        # $spawn->terminate here -- both go through sync_request
        # which is very likely what deadlocked us. SIGKILL the
        # harness directly and move on.
        print STDERR "Command::test: run did not complete within ${timeout}s\n";
        my $pid = eval { $spawn->pid };
        if ($pid) {
            print STDERR "Command::test: sending SIGKILL to harness pid $pid\n";
            kill 'KILL', $pid;
        }
        eval { $spawn->wait;                      1 };
        eval { $spawn->clear_terminate_on_destroy; 1 };
        die "Command::test: timed out after ${timeout}s (set YATH_TEST_TIMEOUT to raise the cap)\n";
    }

    # finish() races the service exit the same way run_results does;
    # swallow the same specific peer-gone shapes and let anything
    # else propagate.
    unless (eval { $spawn->finish; 1 }) {
        my $err = $@;
        die $err unless $err =~ $service_gone_re;
    }
    $spawn->wait;

    $settings->workspace->create_option(keep_dirs => 1);

    print "Work directory: $workdir\n";

    # If the service went away before reporting a final state, treat
    # the run as failed -- we lost the pass verdict and cannot guess.
    return 1 unless $final;
    return $final->{pass} ? 0 : 1;
}

1;

__END__

=head1 POD IS AUTO-GENERATED
