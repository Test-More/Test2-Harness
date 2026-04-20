package App::Yath2::Command::test;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Temp ();
use Time::HiRes qw/time/;

use Test2::Harness2::Util qw/tinysleep/;

use Object::HashBase qw{
    <script
    <config
    <user_config
};

# How long to wait for the harness service to drain (all runs complete,
# no jobs running) before giving up on the IPC-query tally. Real test
# suites finish in seconds to minutes; this is the upper bound before
# the command gives up and reports an infrastructure failure.
use constant DRAIN_TIMEOUT_SECS => 3600;

# How often to poll the service for its current status while waiting
# for drain. Short enough to stay responsive; long enough to not burn
# CPU or IPC bandwidth on a real run.
use constant DRAIN_POLL_INTERVAL_SECS => 0.05;

# The test command's argv is stored as a string hash key because Perl
# reserves the bareword ARGV for the magic filehandle. See App::Yath2
# for the same workaround.
sub argv { $_[0]->{argv} }

sub init {
    my $self = shift;
    $self->{argv} //= [];
    return;
}

sub run {
    my $self = shift;

    require App::Yath2::Finder::Simple;

    my $argv = $self->argv;

    unless (@$argv) {
        print STDERR "yath test: no tests given\n";
        print STDERR "Usage: yath test FILE [FILE...] | DIRECTORY [DIRECTORY...]\n";
        return 2;
    }

    my $ok = eval { _run_tests($argv) };
    unless (defined $ok) {
        my $err = $@;
        print STDERR "yath test: error: $err\n";
        return 2;
    }
    return $ok;
}

sub _run_tests {
    my ($paths) = @_;

    require Test2::Harness2;

    my @tests = App::Yath2::Finder::Simple->find(@$paths);
    unless (@tests) {
        print STDERR "yath test: no test files discovered under given paths\n";
        return 2;
    }

    my $dir = File::Temp->newdir('yath-test-XXXXXX', TMPDIR => 1);

    print STDOUT "yath test: running ", scalar(@tests), " test file(s) under $dir\n";

    # No finish_after_initial_run: the service stays up while we
    # poll for drain and query the tally. We send finish() ourselves
    # once we have the counts. Per PLAN's "State and control flow:
    # IPC, not on-disk artifacts" section, the pass/fail verdict
    # must come from IPC, not from any logger-written file. Queue
    # the run over IPC (not via spawn's test_run shortcut) so the
    # command knows the run_id -- future Command::run will use the
    # same pattern against an existing multi-run harness, where
    # scoping the tally to one specific run_id is required.
    my $spawn = Test2::Harness2->spawn(workdir => "$dir");

    my $queue_resp = $spawn->queue_test_run(files => \@tests);
    my $run_id     = ref($queue_resp) eq 'HASH' ? $queue_resp->{run_id} : undef;
    croak "queue_test_run did not return a run_id"
        unless defined $run_id && length $run_id;

    my ($pass, $fail) = _query_run_tally_via_ipc($spawn, $run_id);

    # Tell the service it's done and wait for it to exit.
    # Spawn->wait calls waitpid(), which sets $?. Perl's exit() propagates
    # $? from END/DESTROY cleanup back to the parent, so the service's
    # own wait-status would silently clobber the exit code we compute
    # from the IPC-reported verdicts. Localize $? across the wait to
    # prevent that leak.
    $spawn->finish;
    {
        local $?;
        $spawn->wait;
    }

    print STDOUT "yath test: pass=$pass fail=$fail\n";

    return $fail ? 1 : 0;
}

# Poll the harness service for the specific run this command queued.
# Returns (pass, fail) once that run has drained. This is deliberately
# run-scoped rather than a harness-global query: the harness may be
# running other runs concurrently (today only via in-process callers;
# tomorrow via the 'yath run' command against a daemonized harness),
# and the command's exit code must reflect only the run it queued.
sub _query_run_tally_via_ipc {
    my ($spawn, $run_id) = @_;

    my $deadline = time + DRAIN_TIMEOUT_SECS;
    my $last;

    while (1) {
        $last = $spawn->run_status($run_id);

        my $state = ref($last) eq 'HASH' ? ($last->{state} // '') : '';
        my $drained =
              $state eq 'completed'                                                           ? 1
            : $state eq 'running' && !@{$last->{pending} // []} && !@{$last->{running} // []} ? 1
            :                                                                                   0;

        last if $drained;

        die "yath test: timed out waiting for run '$run_id' to drain\n"
            if time >= $deadline;

        tinysleep(DRAIN_POLL_INTERVAL_SECS);
    }

    croak "run_status did not return ok for run '$run_id'"
        unless ref($last) eq 'HASH' && $last->{ok};

    return ($last->{pass_count} // 0, $last->{fail_count} // 0);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::test - Minimal 'yath test' command (Stage 5).

=head1 DESCRIPTION

Stage 5 implementation of the C<yath test> command. Accepts a list of
positional test-file / directory arguments, no options, and runs them
through a transient L<Test2::Harness2> service.

The command:

=over 4

=item * Uses L<App::Yath2::Finder::Simple> to expand directories into
        C<*.t> files.

=item * Creates a temporary workdir via L<File::Temp>.

=item * Calls C<< Test2::Harness2->spawn(...) >> to start a harness
        service (no C<finish_after_initial_run>; the command drives
        the finish explicitly).

=item * Queues the test files via IPC
        (C<< $spawn->queue_test_run(files => ...) >>) and captures
        the returned C<run_id>.

=item * Polls the service's C<run_status> handler for that one
        C<run_id> until the run has drained.

=item * Reads the per-run C<pass_count> / C<fail_count> from the
        response — no file on disk is load-bearing for the verdict
        (see PLAN's "State and control flow" section), and the tally
        is scoped to the run this command queued (the harness may
        carry other runs concurrently once C<yath run> lands).

=item * Sends C<finish> and waits for the service process to exit.

=item * Exits 0 if every job passed; exits 1 if any job failed;
        exits 2 on a usage error (missing args, bad paths, crashed
        setup).

=back

Rendering is not hooked up in this stage — pretty output arrives in
Stage 12.

=head1 SYNOPSIS

    perl -Ilib scripts/yath test t/AI/unit/Util.t
    perl -Ilib scripts/yath test t/AI/unit/

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
