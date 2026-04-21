package App::Yath2::Command::run;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Time::HiRes qw/time/;

use Test2::Harness2::Util qw/tinysleep load_module/;

use App::Yath2::Daemon;

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
    'App::Yath2::Options::Tests',
    'App::Yath2::Options::Renderer',
);

use Object::HashBase qw{
    <script
    <config
    <user_config
};

sub argv { $_[0]->{argv} }

sub init {
    my $self = shift;
    $self->{argv} //= [];
    return;
}

sub _parse_argv {
    my ($argv) = @_;
    return parse_options($argv, skip_non_opts => 1, stops => ['--']);
}

# `yath run`: submit a test run to an already-running daemon and
# follow it to completion. Mirrors `yath test`'s shape -- positional
# args become test files -- but attaches to the daemon via the
# pointer file instead of spawning a fresh harness.
sub run {
    my $self = shift;

    my $parsed = eval { _parse_argv([@{$self->argv}]) };
    unless (defined $parsed) {
        print STDERR "yath run: option parse failed: $@\n";
        return 2;
    }

    my @positional = @{$parsed->{skipped} // []};
    push @positional => @{$parsed->{remains}} if $parsed->{remains};

    # Peel out --daemon-workdir if present in the positional args.
    # It would normally live under a shared IPC option group; until
    # that's wired, scan positional manually.
    my ($daemon_workdir);
    @positional = grep {
        if (/^--daemon-workdir=(.*)$/) {
            $daemon_workdir = $1;
            0;
        }
        else {
            1;
        }
    } @positional;

    unless (@positional) {
        print STDERR "yath run: no tests given\n";
        print STDERR "Usage: yath run [OPTIONS] FILE [FILE...] | DIRECTORY [DIRECTORY...]\n";
        return 2;
    }

    my $settings = $parsed->{settings};
    my $verbose  = eval { $settings->renderer->verbose } // 0;
    my $mode = _resolve_mode($settings);

    # Load CLI-side plugins and fire client_setup before the rest of
    # the command does work. The harness-side plugin hooks
    # (run_queued, etc.) don't run from this command -- they fire on
    # the daemon where the run actually executes, against whatever
    # plugins the daemon was started with. client_* are the command-
    # side lifecycle hooks that make sense to run here.
    my $plugins = eval { _load_plugins($settings) };
    unless (defined $plugins) {
        my $err = $@;
        print STDERR "yath run: plugin load failed: $err\n";
        return 2;
    }

    $_->client_setup(settings => $settings) for @$plugins;

    my $spawn = eval { App::Yath2::Daemon::attach(daemon_workdir => $daemon_workdir) };
    unless ($spawn) {
        my $err = $@;
        print STDERR "yath run: cannot attach to daemon: $err";
        $_->client_teardown(settings => $settings)      for reverse @$plugins;
        $_->client_finalize(settings => $settings, exit => \2) for reverse @$plugins;
        return 2;
    }

    require App::Yath2::Finder::Simple;
    my @tests = App::Yath2::Finder::Simple->find(@positional);
    unless (@tests) {
        print STDERR "yath run: no test files discovered under given paths\n";
        $_->client_teardown(settings => $settings)      for reverse @$plugins;
        $_->client_finalize(settings => $settings, exit => \2) for reverse @$plugins;
        return 2;
    }

    print STDOUT "yath run: queueing ", scalar(@tests), " test(s) on daemon pid ",
        $spawn->pid, " (mode=$mode)\n";

    # Per IPC_AND_LOGGERS section 4 the harness rejects queue_run
    # after finish_after_queued. Surface the daemon's error cleanly.
    my $qres = eval { $spawn->queue_test_run(files => \@tests) };
    unless (ref($qres) eq 'HASH' && $qres->{ok}) {
        my $err = $@;
        print STDERR "yath run: queue_test_run rejected: ",
            (ref($qres) eq 'HASH' ? ($qres->{error} // '(no error)') : ($err // '(no response)')),
            "\n";
        $_->client_teardown(settings => $settings)      for reverse @$plugins;
        $_->client_finalize(settings => $settings, exit => \1) for reverse @$plugins;
        return 1;
    }

    my $run_id = $qres->{run_id};
    croak "queue_test_run did not return a run_id" unless defined $run_id;

    my $renderers = eval { _load_renderers($settings) };
    unless (defined $renderers) {
        my $err = $@;
        print STDERR "yath run: renderer load failed: $err\n";
        $_->client_teardown(settings => $settings)      for reverse @$plugins;
        $_->client_finalize(settings => $settings, exit => \2) for reverse @$plugins;
        return 2;
    }

    my ($pass, $fail);
    if (@$renderers) {
        require App::Yath2::ArtifactReader;
        my $layer = App::Yath2::ArtifactReader->new(
            spawn     => $spawn,
            run_id    => $run_id,
            renderers => $renderers,
            mode      => $mode,
        );
        my $final = $layer->run;
        $pass = $final->{pass_count} // 0;
        $fail = $final->{fail_count} // 0;
    }
    else {
        ($pass, $fail) = _query_run_tally_via_ipc($spawn, $run_id);
    }

    print STDOUT "yath run: pass=$pass fail=$fail\n";

    my $exit = $fail ? 1 : 0;
    $_->client_teardown(settings => $settings) for reverse @$plugins;
    $_->client_finalize(settings => $settings, exit => \$exit) for reverse @$plugins;

    return $exit;
}

# Load plugins from --plugin / -p arguments. Mirrors the shape used
# by App::Yath2::Command::test so both commands pick up the same
# plugin set when given the same --plugin argv. Returns an arrayref
# (possibly empty) or dies with a loader error.
sub _load_plugins {
    my ($settings) = @_;

    require App::Yath2::Plugins;

    my $specs = eval { $settings->yath->plugins } // {};
    $specs = {} unless ref($specs) eq 'HASH';

    return App::Yath2::Plugins->load_plugins($specs);
}

sub _resolve_mode {
    my ($settings) = @_;
    my $rs = eval { $settings->renderer };
    return 'default' unless defined $rs;

    my $qvf     = eval { $rs->qvf };
    my $quiet   = eval { $rs->quiet };
    my $verbose = eval { $rs->verbose };

    return 'qvf'     if $qvf;
    return 'quiet'   if $quiet  && !$verbose;
    return 'verbose' if $verbose;
    return 'default';
}

sub _load_renderers {
    my ($settings) = @_;

    my $rs = eval { $settings->renderer };
    return [] unless defined $rs;

    my $classes = eval { $rs->classes };
    $classes = {} unless ref($classes) eq 'HASH';

    my @out;
    for my $class (sort keys %$classes) {
        my $args = $classes->{$class} // [];
        $args = [] unless ref($args) eq 'ARRAY';

        my $ok = eval { load_module($class); 1 };
        my $err = $@;
        die "renderer class '$class' failed to load: $err" unless $ok;

        my %h = @$args % 2 == 0 ? @$args : map { $_ => 1 } @$args;
        push @out => $class->new(%h);
    }

    return \@out;
}

sub _query_run_tally_via_ipc {
    my ($spawn, $run_id) = @_;

    my $deadline = time + 3600;
    my $last;

    while (1) {
        $last = $spawn->run_status($run_id);

        my $state = ref($last) eq 'HASH' ? ($last->{state} // '') : '';
        my $drained =
              $state eq 'completed'                                                           ? 1
            : $state eq 'running' && !@{$last->{pending} // []} && !@{$last->{running} // []} ? 1
            :                                                                                   0;

        last if $drained;

        die "yath run: timed out waiting for run '$run_id' to drain\n"
            if time >= $deadline;

        tinysleep(0.05);
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

App::Yath2::Command::run - Submit a run to an existing yath daemon.

=head1 SYNOPSIS

    yath run t/a.t t/b.t
    yath run --daemon-workdir=/tmp/yath2-12345-AbCdEf t/
    yath run -v t/

=head1 DESCRIPTION

The daemon-attached cousin of C<yath test>. Discovers the running
daemon (via L<App::Yath2::Daemon>), submits the provided test files
as a new run via C<queue_test_run>, and follows the run to
completion using the same artifact-reading layer C<yath test> uses
(L<App::Yath2::ArtifactReader>) when any renderer is configured.

Exits 0 on all-pass; 1 on any failure; 2 on usage / attach error.

=cut
