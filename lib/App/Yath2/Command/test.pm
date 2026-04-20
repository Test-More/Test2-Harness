package App::Yath2::Command::test;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Temp ();
use Time::HiRes qw/time/;

use Test2::Harness2::Util qw/tinysleep/;

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
    'App::Yath2::Options::Tests',
    'App::Yath2::Options::Renderer',
    'App::Yath2::Options::Resource',
    'App::Yath2::Options::Runner',
);

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

# Exposed as a named sub so unit tests can invoke option parsing without
# needing to construct a full command object. parse_options is a closure
# over the options instance for the package that imported Getopt::Yath,
# so the call has to happen from inside this package.
sub _parse_argv {
    my ($argv) = @_;
    return parse_options($argv, skip_non_opts => 1, stops => ['--']);
}

sub run {
    my $self = shift;

    my $parsed = eval { _parse_argv([@{$self->argv}]) };
    unless (defined $parsed) {
        my $err = $@;
        print STDERR "yath test: option parse failed: $err\n";
        return 2;
    }

    my @positional = @{$parsed->{skipped} // []};
    push @positional => @{$parsed->{remains}} if $parsed->{remains};

    unless (@positional) {
        print STDERR "yath test: no tests given\n";
        print STDERR "Usage: yath test [OPTIONS] FILE [FILE...] | DIRECTORY [DIRECTORY...]\n";
        return 2;
    }

    my $settings    = $parsed->{settings};
    my $launch_args = _build_launch_args($settings, $parsed);
    my $slots       = _resolve_slots($settings);
    my $verbose     = _resolve_verbose($settings);
    my $preloads    = _resolve_preloads($settings);

    _warn_preloads_placeholder($preloads) if @$preloads;

    my $plugins = eval { _load_plugins($settings) };
    unless (defined $plugins) {
        my $err = $@;
        print STDERR "yath test: plugin load failed: $err\n";
        return 2;
    }

    $_->client_setup(settings => $settings) for @$plugins;

    my $ok  = eval { _run_tests(\@positional, $launch_args, $slots, $verbose, $plugins) };
    my $err = $@;

    $_->client_teardown(settings => $settings) for reverse @$plugins;
    $_->client_finalize(settings => $settings, exit => \$ok) for reverse @$plugins;

    unless (defined $ok) {
        print STDERR "yath test: error: $err\n";
        return 2;
    }
    return $ok;
}

# Build the plugin list from $settings->yath->plugins (a Map keyed by
# fully-qualified class name). Returns an empty arrayref when no
# plugins were requested so every call site can dispatch unconditionally.
sub _load_plugins {
    my ($settings) = @_;

    require App::Yath2::Plugins;

    my $specs = eval { $settings->yath->plugins } // {};
    $specs = {} unless ref($specs) eq 'HASH';

    return App::Yath2::Plugins->load_plugins($specs);
}

# Build the arrayref of perl -I... switches that the harness injects
# between $^X and the absolute test file. Semantics mirror the old yath
# defaults:
#
#   -I PATH      -> -IPATH
#   --lib        -> -Ilib
#   --blib       -> -Iblib/lib -Iblib/arch
#   --no-lib     -> suppress auto-inclusion of lib/
#   --no-blib    -> suppress auto-inclusion of blib/
#
# If the user passes neither --lib nor --no-lib, lib/ is auto-included
# when ./lib exists; same pattern for blib.
sub _build_launch_args {
    my ($settings, $parsed) = @_;

    my $cleared = $parsed->{cleared} // {};

    my $includes = eval { $settings->tests->includes } // [];
    $includes = [] unless ref($includes) eq 'ARRAY';

    my $lib_explicit_on   = eval { $settings->tests->lib }  ? 1 : 0;
    my $blib_explicit_on  = eval { $settings->tests->blib } ? 1 : 0;
    my $lib_explicit_off  = _was_cleared($cleared, 'tests', 'lib');
    my $blib_explicit_off = _was_cleared($cleared, 'tests', 'blib');

    my $lib_on  = $lib_explicit_on  || (!$lib_explicit_off  && -d 'lib');
    my $blib_on = $blib_explicit_on || (!$blib_explicit_off && -d 'blib');

    my @paths;
    push @paths => @$includes;
    push @paths => 'lib' if $lib_on;
    push @paths => 'blib/lib', 'blib/arch' if $blib_on;

    return [map { "-I$_" } @paths];
}

# Getopt::Yath's cleared bookkeeping lives under $parsed->{cleared}.
# The shape is not tightly documented, so check the most likely keys
# defensively: either a flat "<group>.<opt>" key or a nested
# { group => { opt => 1 } } hash. Either way returns true when the
# user explicitly passed --no-<opt>.
sub _was_cleared {
    my ($cleared, $group, $opt) = @_;
    return 0 unless ref($cleared) eq 'HASH';

    my $group_cleared = $cleared->{$group};
    return 1 if ref($group_cleared) eq 'HASH' && $group_cleared->{$opt};

    return 1 if $cleared->{"$group.$opt"};
    return 1 if $cleared->{$opt};

    return 0;
}

# Map --slots N (a.k.a. -j N, --job-count N) to the JobCount resource's
# slot count. Fall back to 1 so the single-run default mirrors what the
# harness uses when no resource is supplied (Test2::Harness2::_init_resources).
sub _resolve_slots {
    my ($settings) = @_;

    my $slots = eval { $settings->resource->slots };
    return 1 unless defined $slots && $slots =~ m/^\d+$/ && $slots > 0;
    return $slots;
}

sub _resolve_verbose {
    my ($settings) = @_;
    my $v = eval { $settings->renderer->verbose };
    return $v // 0;
}

sub _resolve_preloads {
    my ($settings) = @_;
    my $p = eval { $settings->runner->preloads };
    return [] unless ref($p) eq 'ARRAY';
    return $p;
}

sub _warn_preloads_placeholder {
    my ($preloads) = @_;
    print STDERR "yath test: --preload is accepted as a placeholder in this stage " . "but not yet wired through; the following preloads were ignored: " . join(', ', @$preloads) . "\n";
}

sub _run_tests {
    my ($paths, $launch_args, $slots, $verbose, $plugins) = @_;
    $plugins //= [];

    require App::Yath2::Finder::Simple;
    require Test2::Harness2;
    require Test2::Harness2::Resource::JobCount;

    my @tests = App::Yath2::Finder::Simple->find(@$paths);
    unless (@tests) {
        print STDERR "yath test: no test files discovered under given paths\n";
        return 2;
    }

    my $dir = File::Temp->newdir('yath-test-XXXXXX', TMPDIR => 1);

    print STDOUT "yath test: running ", scalar(@tests), " test file(s) under $dir",
        ($verbose ? " (verbose=$verbose)" : ""), "\n";

    my @resources = (Test2::Harness2::Resource::JobCount->new(slots => $slots));

    # No finish_after_initial_run: the service stays up while we
    # poll for drain and query the tally. We send finish() ourselves
    # once we have the counts. Per PLAN's "State and control flow:
    # IPC, not on-disk artifacts" section, the pass/fail verdict
    # must come from IPC, not from any logger-written file. Queue
    # the run over IPC (not via spawn's test_run shortcut) so the
    # command knows the run_id -- future Command::run will use the
    # same pattern against an existing multi-run harness, where
    # scoping the tally to one specific run_id is required.
    my $spawn = Test2::Harness2->spawn(
        workdir   => "$dir",
        resources => \@resources,
        plugins   => $plugins,
        (@$launch_args ? (launch_args => $launch_args) : ()),
    );

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
