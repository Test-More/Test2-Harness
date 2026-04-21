package App::Yath2::Plugin::Cover;
use strict;
use warnings;

our $VERSION = '2.000011';

use Test2::Harness2::Util qw/clean_path mod2file fqmod/;

use Role::Tiny::With;
with 'App::Yath2::Role::Plugin';

use Object::HashBase qw{-aggregator -no_aggregate +metrics +outfile};

use Getopt::Yath;

# HAS_TEST2_PLUGIN_COVER gates the "do we force-load
# Test2::Plugin::Cover into every test?" branch. Absent module ->
# no-op instead of a load failure. Per CLAUDE.md this is an
# acceptable "optional module" eval.
use constant HAS_TEST2_PLUGIN_COVER => eval { require Test2::Plugin::Cover; 1 } ? 1 : 0;

option_group {prefix => 'cover', group => 'cover', category => "Cover Options"} => sub {
    option_post_process \&post_process;

    option types => (
        alt     => ['type'],
        type    => 'List',
        default => sub { qw/pl pm/ },
    );

    option dirs => (
        alt       => ['dir'],
        type      => 'List',
        default   => sub { qw{ lib } },
        normalize => sub { glob($_[0]) },
    );

    option exclude_private => (
        type        => 'Bool',
        default     => 0,
        description => "Exclude subs prefixed with '_' from coverage metrics",
    );

    option files => (
        type        => 'Bool',
        description => "Use Test2::Plugin::Cover to collect coverage data for what files are touched by what tests. Unlike Devel::Cover this has very little performance impact (About 4% difference)",
    );

    option metrics => (
        type        => 'Bool',
        description => 'Build the metrics data',
    );

    option write => (
        type          => 'Auto',
        normalize     => \&clean_path,
        long_examples => ['', '=coverage.jsonl', '=coverage.json'],
        description   => "Create a json or jsonl file of all coverage data seen during the run (This implies --cover-files).",
        autofill      => sub { clean_path("coverage.jsonl") },
    );

    option aggregator => (
        type          => 'Scalar',
        alt           => ['agg'],
        long_examples => [' ByTest', ' ByRun', ' +Custom::Aggregator'],
        description   => 'Choose a custom aggregator subclass',
        normalize     => sub { fqmod($_[0], 'App::Yath2::Log::CoverageAggregator') },
    );

    option class => (
        type        => 'Scalar',
        description => 'Choose a Test2::Plugin::Cover subclass',
        default     => 'Test2::Plugin::Cover',
    );

    option manager => (
        type          => 'Scalar',
        description   => "Coverage 'from' manager to use when coverage data does not provide one",
        long_examples => [' My::Coverage::Manager'],
        applicable    => \&changes_applicable,
    );

    option from_type => (
        type          => 'Scalar',
        description   => 'File type for coverage source. Usually it can be detected, but when it cannot be you should specify. "json" is old style single-blob coverage data, "jsonl" is the new by-test style, "log" is a logfile from a previous run.',
        long_examples => [' json', ' jsonl', ' log'],
    );

    option maybe_from_type => (
        type          => 'Scalar',
        description   => 'Same as "from_type" but for "maybe_from". Defaults to "from_type" if that is specified, otherwise auto-detect',
        long_examples => [' json', ' jsonl', ' log'],
    );

    option from => (
        type          => 'Scalar',
        description   => "This can be a test log, a coverage dump (old style json or new jsonl format), or a url to any of the previous. Tests will not be run if the file/url is invalid.",
        long_examples => [' path/to/log.jsonl', ' http://example.com/coverage', ' path/to/coverage.jsonl'],
    );

    option maybe_from => (
        type          => 'Scalar',
        description   => "This can be a test log, a coverage dump (old style json or new jsonl format), or a url to any of the previous. Tests will coninue if even if the coverage file/url is invalid.",
        long_examples => [' path/to/log.jsonl', ' http://example.com/coverage', ' path/to/coverage.jsonl'],
    );
};

sub changes_applicable {
    my ($option, $options, $settings) = @_;

    return 0 unless $settings;
    return 0 unless $settings->check_group('yath');

    my $yath = $settings->yath;
    return 0 unless $yath->check_option('command');
    my $command = $yath->command or return 0;

    # Cannot use these options with projects
    return 0 if $command->isa('App::Yath2::Command::projects');
    return 1;
}

# option_post_process callback. Runs after option parsing and wires
# Test2::Plugin::Cover into the test-load chain when coverage
# collection is requested. This is a direct port of old/; it depends
# on two Stage 6 options (tests->load_import and runner->preload_early)
# that are currently commented-out. When either option group is
# inactive we skip the corresponding wiring (marked deferred inline
# below) -- the rest of the plugin (options, run metadata) still works.
sub post_process {
    my ($options, $state) = @_;
    my $settings = $state->{settings};

    return unless $settings->check_group('cover');

    my $cover = $settings->cover;

    return unless $cover->files || $cover->write || $cover->metrics;

    my $cover_class = $cover->class // 'Test2::Plugin::Cover';

    eval { require(mod2file($cover_class)); 1 }
        or die "Could not enable file coverage, could not load '$cover_class': $@";

    # Deferred: when tests->load_import is re-activated (blocked by the
    # Stage 6 TODO on App::Yath2::Options::Tests' --load-import option),
    # this force-inject path hoisted verbatim from old/ takes effect.
    # Resolved-by: Stage 6 follow-up activation of tests->load_import.
    if ($settings->check_group('tests')) {
        my $tests = $settings->tests;
        if ($tests->can('load_import')) {
            $tests->option(load_import => {}) unless $tests->load_import;
            push @{$tests->load_import->{'@'}} => $cover_class;
            $tests->load_import->{$cover_class} = [];
        }
    }

    # Deferred: preload-early injection is blocked by the Stage 8 TODO
    # on App::Yath2::Options::Runner's --preload-early option.
    # Resolved-by: Stage 8 follow-up activation of runner->preload_early.
    if ($settings->check_group('runner')) {
        my $runner = $settings->runner;
        if ($runner->can('preload_early')) {
            $runner->option(preload_early => {}) unless $runner->preload_early;
            unshift @{$runner->preload_early->{'@'}} => $cover_class;
            $runner->preload_early->{$cover_class} = [disabled => 1];
        }
    }
}

# run_queued: no stamped run field yet -- the old plugin's coverage
# field gets synthesized from annotate_event output at end of run,
# and annotate_event depends on the renderer-event dispatch chain
# that Stage 12 introduced but hasn't fully wired to plugins. Stage
# 15 keeps the plugin option-group-complete and CLI-usable; the
# field-emitting path returns when the upstream dispatch does.
#
# Deferred: routing collector / artifact-reader events through a
# plugin's annotate_event callback is a Stage 10 audit item -- the
# coverage-aggregator port ships with its own event-dispatch wiring.
# Resolved-by: Stage 10 successor plan (coverage-aggregator reinstate).
sub run_queued { return }

# annotate_event is the entry point renderer code (and the
# artifact-reader layer) will call per-event once plugin-event
# wiring lands. Left in place so the Stage 15 surface matches old/,
# but returns empty until its aggregator dependency is also ported.
#
# Deferred: requires porting App::Yath2::Log::CoverageAggregator +
# ByRun + ByTest. The old implementation lives at
# old/lib/Test2/Harness2/Log/CoverageAggregator*.pm and its audit
# landed in Stage 10 (docs/log-port-audit.md). The aggregators are
# not needed until the coverage / summary renderer is revived.
# Resolved-by: Stage 10 successor plan (coverage-aggregator reinstate).
sub annotate_event {
    my $self = shift;
    return if $self->{+NO_AGGREGATE};

    # With no aggregator available, don't pretend to consume events.
    $self->{+NO_AGGREGATE} = 1;
    return;
}

sub metrics {
    my $self = shift;
    my ($settings) = @_;

    my $cover = $settings->cover;

    return unless $cover->metrics;

    my $aggregator = $self->{+AGGREGATOR};
    return unless $aggregator;

    return $self->{+METRICS} //= $aggregator->build_metrics(
        dirs            => $cover->dirs,
        types           => $cover->types,
        exclude_private => $cover->exclude_private,
    );
}

# Called at CLI shutdown. When metrics / write are enabled and the
# aggregator has data, print a human summary. With no aggregator
# wired yet this is a no-op.
sub client_finalize {
    my $self = shift;
    my (%params) = @_;

    my $settings = $params{settings};

    return unless $settings->check_group('cover');
    my $cover = $settings->cover;

    my $file    = $cover->write;
    my $metrics = $cover->metrics;

    return unless $file || $metrics;

    my $aggregator = $self->{+AGGREGATOR};
    return unless $aggregator;

    print "\nCoverage:\n";

    if ($metrics) {
        my $data = $self->metrics($settings);

        require Term::Table;
        my $table = Term::Table->new(
            header => [qw/METRIC TOTAL TESTED PERCENTAGE/],
            rows   => $self->_percentages($data),
        );
        print map { "$_\n" } $table->render;
    }

    print "Wrote coverage file: $file\n" if $file;

    print "\n";
}

sub _percentages {
    my $self = shift;
    my ($metrics) = @_;

    return unless $metrics;

    my @out;

    for my $metric (sort keys %$metrics) {
        next if $metric eq 'untested';
        my $data = $metrics->{$metric} or next;
        my ($total, $tested) = @{$data}{qw/total tested/};
        push @out => [$metric, $total, $tested, $total ? (int(($tested / $total) * 100) . '%') : '100%'];
    }

    return \@out;
}

sub TO_JSON { ref($_[0]) || "$_[0]" }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Plugin::Cover - Plugin to collect and report basic coverage data

=head1 DESCRIPTION

Simple coverage data, file and sub coverage only. Use L<Devel::Cover> if
you want deep coverage stats.

=head1 STATUS (Stage 15)

The Cover plugin ships in Stage 15 with its option surface intact and
plugin-loading wired in, but its aggregator dependencies
(C<App::Yath2::Log::CoverageAggregator> and the C<ByRun> / C<ByTest>
subclasses) are **deferred** until the upstream hooks they need are
active.

Specifically:

=over 4

=item *

C<annotate_event> returns empty because the collector-side / artifact-
reading-layer event dispatch hasn't been extended to call plugins yet
(a Stage 18 item).

=item *

C<post_process> skips its C<load_import> / C<preload_early> injections
unless those Stage 6 option groups have been activated. With Stage 6
as-is neither option is live, so the option group parses and the
plugin's CLI is usable, but C<Test2::Plugin::Cover> is not forced into
every test.

=item *

C<run_queued> returns no run field. The old plugin synthesised its
C<coverage> field from event-stream output; bringing that back waits
on the aggregators.

=back

See C<docs/log-port-audit.md> (Stage 10) for the audit that set
this scope.

=head1 OPTIONAL DEPENDENCIES

=over 4

=item L<Test2::Plugin::Cover> -- the in-test coverage collector.
Gated via C<HAS_TEST2_PLUGIN_COVER>; missing on the system means
coverage collection can't be turned on, but the option group still
parses.

=item L<Term::Table> -- used only by C<client_finalize> for the
percentages summary. Loaded lazily.

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
