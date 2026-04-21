package App::Yath2::Command::test;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Cwd ();
use File::Temp ();
use File::Spec ();
use Time::HiRes qw/time/;

use Test2::Harness2::Util qw/tinysleep load_module/;

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
    'App::Yath2::Options::Tests',
    'App::Yath2::Options::Renderer',
    'App::Yath2::Options::Resource',
    'App::Yath2::Options::Runner',
    'App::Yath2::Options::Finder',
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

    my $settings = $parsed->{settings};

    # --help / --help=GROUP short-circuit. The Options::Yath 'help'
    # option activates as part of Stage 6; we check for it here so
    # `yath test --help` and `yath test --help=GROUP` bail out with
    # the relevant help text before the no-tests-given guard below
    # tries to error on what looks like an empty positional list.
    my $help = eval { ${$settings->yath->option_ref('help', 1)} };
    if (defined $help) {
        my $group = ($help eq '1') ? undef : $help;
        return $self->_print_help($group);
    }

    my @positional = @{$parsed->{skipped} // []};
    push @positional => @{$parsed->{remains}} if $parsed->{remains};

    unless (@positional) {
        print STDERR "yath test: no tests given\n";
        print STDERR "Usage: yath test [OPTIONS] FILE [FILE...] | DIRECTORY [DIRECTORY...]\n";
        return 2;
    }

    my $launch_args = _build_launch_args($settings, $parsed);
    my $slots       = _resolve_slots($settings);
    my $verbose     = _resolve_verbose($settings);
    my $preloads    = _resolve_preloads($settings);
    my $extensions  = _resolve_extensions($settings);
    my $renderers   = eval { _load_renderers($settings) };
    unless (defined $renderers) {
        my $err = $@;
        print STDERR "yath test: renderer load failed: $err\n";
        return 2;
    }
    my $mode = _resolve_mode($settings);

    my $plugins = eval { _load_plugins($settings) };
    unless (defined $plugins) {
        my $err = $@;
        print STDERR "yath test: plugin load failed: $err\n";
        return 2;
    }

    $_->client_setup(settings => $settings) for @$plugins;

    my $shared_jobs = _resolve_shared_jobs($settings, $slots);

    my $ok  = eval { _run_tests(\@positional, $launch_args, $slots, $verbose, $preloads, $plugins, $renderers, $mode, $shared_jobs, $extensions) };
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
sub _print_help {
    my $self    = shift;
    my ($group) = @_;

    # Build a Getopt::Yath::Instance carrying this command's full
    # include_options chain so docs() sees every option the command
    # can accept. Render either the whole option set or a single
    # group depending on $group.
    require Getopt::Yath::Instance;
    my $inst = Getopt::Yath::Instance->new(
        category_sort_map => {
            'NO CATEGORY - FIX ME' => 99999,
            'Yath Options'         => -100,
            'Command Options'      => -90,
            'Harness Options'      => -80,
        },
    );
    $inst->include(App::Yath2::Options::Yath->options);
    $inst->include(App::Yath2::Options::Tests->options);
    $inst->include(App::Yath2::Options::Renderer->options);
    $inst->include(App::Yath2::Options::Resource->options);
    $inst->include(App::Yath2::Options::Runner->options);
    $inst->include(App::Yath2::Options::Finder->options);

    my $text = $inst->docs('cli', defined($group) ? (group => $group) : ());
    print STDOUT $text;
    return 0;
}

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

    # Pull any directories published via T2_HARNESS_INCLUDES onto the
    # launch -I list so nested yath invocations inherit their caller's
    # @INC. scripts/yath republishes @INC into T2_HARNESS_INCLUDES on
    # every invocation, so the chain of nested -I paths stays intact.
    # Match old/'s TestSettings::includes behaviour: '.' is filtered out
    # and the full path list is deduplicated below.
    if (my $env_inc = $ENV{T2_HARNESS_INCLUDES}) {
        push @paths => grep { $_ ne '.' } split /;/, $env_inc;
    }

    # Canonicalize every path to absolute-from-cwd before emitting -I
    # switches. Relative paths in @INC survive exactly as long as the
    # inheriting process keeps the harness's cwd; any test that chdirs
    # (and in particular any test that defers Test2::Formatter::Stream2
    # loading past a chdir) then can't locate its own modules and the
    # lazy formatter-require dies. Absolute paths make the launched
    # perl's @INC cwd-independent.
    my $cwd = Cwd::getcwd();
    my @absolute = map { File::Spec->file_name_is_absolute($_) ? $_ : File::Spec->rel2abs($_, $cwd) } @paths;

    my %seen;
    my @deduped = grep { !$seen{$_}++ } @absolute;

    return [map { "-I$_" } @deduped];
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

# Pull the extensions list from --extension / --ext. Empty list means
# "use Finder::Simple's default" so we keep the single source of truth
# for the default (t, t2) in the finder.
sub _resolve_extensions {
    my ($settings) = @_;
    my $e = eval { $settings->finder->extensions };
    return [] unless ref($e) eq 'ARRAY';
    return $e;
}

# Decide whether to attach the App::Yath2::Resource::SharedJobSlots
# resource. --shared-jobs has three states:
#
#   undef/not-passed: opt in if (and only if) the config file exists.
#                     This matches old/'s default behaviour.
#   true:             require shared jobs; die if no config file is found.
#   false:            never use shared jobs, even if a config file exists.
#
# Returns undef when shared jobs should be off, or a hashref carrying
# the constructor args for the resource when it should be on. Building
# the actual resource instance lives in _run_tests so the import of
# the heavy module is deferred until really needed.
sub _resolve_shared_jobs {
    my ($settings, $slots) = @_;

    my $resource = eval { $settings->resource };
    return undef unless defined $resource;

    my $shared    = eval { $resource->shared_jobs };
    my $base_name = eval { $resource->shared_jobs_config };
    $base_name //= '.sharedjobslots.yml';

    if (defined $shared) {
        return undef unless $shared;
    }

    # Decide based on presence of a config file. find_in_updir handles
    # bare filenames; an explicit path is checked directly.
    require Test2::Harness2::Util;
    my $config_path = (-e $base_name) ? $base_name : Test2::Harness2::Util::find_in_updir($base_name);

    unless ($config_path && -e $config_path) {
        return undef unless defined $shared && $shared;
        die "--shared-jobs specified, but could not find a config file ('$base_name').\n";
    }

    my $job_slots = 1;
    eval {
        my $s = $resource->job_slots;
        $job_slots = $s if defined $s && $s =~ m/^\d+$/ && $s > 0;
    };

    return {
        slots              => $slots,
        job_slots          => $job_slots,
        shared_jobs_config => $config_path,
    };
}

# Decide which artifact-reader mode to use. quiet/qvf/verbose are
# explicit; otherwise fall through to 'default'. The four values
# match App::Yath2::ArtifactReader's mode enum.
sub _resolve_mode {
    my ($settings) = @_;
    my $rs = eval { $settings->renderer };
    return 'default' unless defined $rs;

    my $qvf     = eval { $rs->qvf };
    my $quiet   = eval { $rs->quiet };
    my $verbose = eval { $rs->verbose };

    return 'qvf'     if $qvf;
    return 'quiet'   if $quiet && !$verbose;
    return 'verbose' if $verbose;
    return 'default';
}

# Instantiate the renderer set from $settings->renderer->classes.
# Each entry is Class => \@args. The class is loaded at this point
# (the option's normalize uses no_require => 1 so parse time stays
# cheap and failures land here with a clearer error).
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

        my $ok  = eval { load_module($class); 1 };
        my $err = $@;
        unless ($ok) {
            die "renderer class '$class' failed to load: $err";
        }

        my $ctor_ok = eval {
            my @ctor_args = @$args;
            # Every in-tree renderer takes a %args hash. If the user
            # passed bare scalars (e.g. -rDefault) @ctor_args is empty;
            # if they passed `=a,b` we treat those as boolean flags
            # keyed by themselves for now.
            my %h = @ctor_args % 2 == 0 ? @ctor_args : map { $_ => 1 } @ctor_args;
            push @out => $class->new(%h);
            1;
        };
        my $ctor_err = $@;
        unless ($ctor_ok) {
            die "renderer class '$class' constructor failed: $ctor_err";
        }
    }

    return \@out;
}

sub _run_tests {
    my ($paths, $launch_args, $slots, $verbose, $preloads, $plugins, $renderers, $mode, $shared_jobs, $extensions) = @_;
    $plugins    //= [];
    $preloads   //= [];
    $renderers  //= [];
    $mode       //= 'default';
    $extensions //= [];

    require App::Yath2::Finder::Simple;
    require Test2::Harness2;

    my @tests;
    if (@$extensions) {
        @tests = App::Yath2::Finder::Simple->find({extensions => $extensions}, @$paths);
    }
    else {
        @tests = App::Yath2::Finder::Simple->find(@$paths);
    }
    unless (@tests) {
        print STDERR "yath test: no test files discovered under given paths\n";
        return 2;
    }

    my $dir = File::Temp->newdir('yath-test-XXXXXX', TMPDIR => 1);

    print STDOUT "yath test: running ", scalar(@tests), " test file(s) under $dir",
        ($verbose     ? " (verbose=$verbose)"                                       : ""),
        (@$preloads   ? " (preload=" . join(',', @$preloads) . ")"                  : ""),
        ($shared_jobs ? " (shared-jobs=" . $shared_jobs->{shared_jobs_config} . ")" : ""),
        (" (mode=$mode)"), "\n";

    # The limiter resource. SharedJobSlots is also a job limiter, so
    # when it's active we use it instead of a plain JobCount (two
    # limiters on the same harness would either both cap or fight --
    # SharedJobSlots is the stricter of the two, pick it when set).
    my @resources;
    if ($shared_jobs) {
        require App::Yath2::Resource::SharedJobSlots;
        push @resources => App::Yath2::Resource::SharedJobSlots->new(%$shared_jobs);
    }
    else {
        require Test2::Harness2::Resource::JobCount;
        push @resources => Test2::Harness2::Resource::JobCount->new(slots => $slots);
    }

    if (@$preloads) {
        require Test2::Harness2::Resource::Preload;
        push @resources => Test2::Harness2::Resource::Preload->new(
            workdir => "$dir",
            preload => [@$preloads],
        );
    }

    # When any renderer is configured we must also put a JSONL
    # logger on each test-job collector so the artifact-reading
    # layer has something to replay in verbose / qvf mode. The
    # harness otherwise installs no loggers by default (see
    # IPC_AND_LOGGERS §12.1).
    my @test_loggers = ();
    if (@$renderers) {
        @test_loggers = ([
            'Test2::Harness2::Collector::Logger::JSONL',
            output_file => '%LOG_DIR%/%JOB_TRY%.jsonl',
        ]);
    }

    # No finish_after_initial_run: the service stays up while the
    # artifact-reader polls for drain. Per PLAN's "State and control
    # flow: IPC, not on-disk artifacts", the pass/fail verdict flows
    # via IPC. Queue the run over IPC (not via spawn's test_run
    # shortcut) so we know the run_id.
    my $spawn = Test2::Harness2->spawn(
        workdir   => "$dir",
        resources => \@resources,
        plugins   => $plugins,
        (@test_loggers ? (test_loggers => \@test_loggers) : ()),
        (@$launch_args ? (launch_args  => $launch_args)   : ()),
    );

    my $queue_resp = $spawn->queue_test_run(files => \@tests);
    my $run_id     = ref($queue_resp) eq 'HASH' ? $queue_resp->{run_id} : undef;
    croak "queue_test_run did not return a run_id"
        unless defined $run_id && length $run_id;

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
