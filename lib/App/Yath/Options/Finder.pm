package App::Yath::Options::Finder;
use strict;
use warnings;

our $VERSION = '1.000154';

use Test2::Harness::Util qw/mod2file/;

use App::Yath::Options;

my %RERUN_MODES = (
    all     => "Re-Run all tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that.",
    failed  => "Re-Run failed tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that.",
    retried => "Re-Run retried tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that.",
    passed  => "Re-Run passed tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that.",
    missed  => "Run missed tests from a previously aborted/stopped run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that.",
);

option_group {prefix => 'finder', category => "Finder Options", builds => 'Test2::Harness::Finder'} => sub {
    option finder => (
        type          => 's',
        default       => 'Test2::Harness::Finder',
        description   => 'Specify what Finder subclass to use when searching for files/processing the file list. Use the "+" prefix to specify a fully qualified namespace, otherwise Test2::Harness::Finder::XXX namespace is assumed.',
        long_examples => [' MyFinder', ' +Test2::Harness::Finder::MyFinder'],
        pre_command   => 1,
        adds_options  => 1,
        pre_process   => \&finder_pre_process,
        action        => \&finder_action,

        builds => undef,    # This option is not for the build
    );

    option extension => (
        field       => 'extensions',
        type        => 'm',
        alt         => ['ext'],
        description => 'Specify valid test filename extensions, default: t and t2',
    );

    option search => (
        type => 'm',

        description => 'List of tests and test directories to use instead of the default search paths. Typically these can simply be listed as command line arguments without the --search prefix.',
    );

    option no_long => (
        description => "Do not run tests that have their duration flag set to 'LONG'",
    );

    option only_long => (
        description => "Only run tests that have their duration flag set to 'LONG'",
    );

    option show_changed_files => (
        description => "Print a list of changed files if any are found",
        applicable => \&changes_applicable,
    );

    option changed_only => (
        description => "Only search for tests for changed files (Requires a coverage data source, also requires a list of changes either from the --changed option, or a plugin that implements changed_files() or changed_diff())",
        applicable => \&changes_applicable,
    );

    option rerun => (
        type => 'd',
        description => "Re-Run tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that.",
        long_examples => ['', '=path/to/log.jsonl', '=plugin_specific_string'],
    );

    option rerun_plugin => (
        type => 'm',
        description => "What plugin(s) should be used for rerun (will fallback to other plugins if the listed ones decline the value, this is just used ot set an order of priority)",
        long_examples => [' Foo', ' +App::Yath::Plugin::Foo'],
    );

    option rerun_modes => (
        alt => ['rerun-mode'],
        type => 'm',
        description => "Pick which test categories to run",
        long_examples => [' failed,missed,...', map {" $_"} sort keys %RERUN_MODES],
    );

    for my $mode (keys %RERUN_MODES) {
        option "rerun_$mode" => (
            type             => 'd',
            description      => $RERUN_MODES{$mode},
            long_examples    => ['', '=path/to/log.jsonl', '=plugin_specific_string'],
            ignore_for_build => 1,
        );
    }

    option changed => (
        type => 'm',
        description => "Specify one or more files as having been changed.",
        long_examples => [' path/to/file'],
        applicable => \&changes_applicable,
    );

    option changes_exclude_file => (
        type => 'm',
        description => 'Specify one or more files to ignore when looking at changes',
        long_examples => [' path/to/file'],
        applicable => \&changes_applicable,
    );

    option changes_exclude_pattern => (
        type => 'm',
        description => 'Ignore files matching this pattern when looking for changes. Your pattern will be inserted unmodified into a `$file =~ m/$pattern/` check.',
        long_examples => [" '(apple|pear|orange)'"],
        applicable => \&changes_applicable,
    );

    option changes_filter_file => (
        type => 'm',
        description => 'Specify one or more files to check for changes. Changes to other files will be ignored',
        long_examples => [' path/to/file'],
        applicable => \&changes_applicable,
    );

    option changes_filter_pattern => (
        type => 'm',
        description => 'Specify a pattern for change checking. When only running tests for changed files this will limit which files are checked for changes. Only files that match this pattern will be checked. Your pattern will be inserted unmodified into a `$file =~ m/$pattern/` check.',
        long_examples => [" '(apple|pear|orange)'"],
        applicable => \&changes_applicable,
    );

    option changes_diff => (
        type => 's',
        description => "Path to a diff file that should be used to find changed files for use with --changed-only. This must be in the same format as `git diff -W --minimal -U1000000`",
        long_examples => [' path/to/diff.diff'],
        applicable => \&changes_applicable,
    );

    option changes_plugin => (
        type => 's',
        description => "What plugin should be used to detect changed files.",
        long_examples => [' Git', ' +App::Yath::Plugin::Git'],
        applicable => \&changes_applicable,
    );

    option changes_include_whitespace => (
        type => 'b',
        description => "Include changed lines that are whitespace only (default: off)",
        applicable => \&changes_applicable,
        default => 0,
    );

    option changes_exclude_nonsub => (
        type => 'b',
        description => "Exclude changes outside of subroutines (perl files only) (default: off)",
        applicable => \&changes_applicable,
        default => 0,
    );

    option changes_exclude_loads => (
        type => 'b',
        description => "Exclude coverage tests which only load changed files, but never call code from them. (default: off)",
        applicable => \&changes_applicable,
        default => 0,
    );

    option changes_exclude_opens => (
        type => 'b',
        description => "Exclude coverage tests which only open() changed files, but never call code from them. (default: off)",
        applicable => \&changes_applicable,
        default => 0,
    );

    option durations => (
        type => 's',

        long_examples  => [' file.json', ' http://example.com/durations.json'],
        short_examples => [' file.json', ' http://example.com/durations.json'],

        description => "Point at a json file or url which has a hash of relative test filenames as keys, and 'SHORT', 'MEDIUM', or 'LONG' as values. This will override durations listed in the file headers. An exception will be thrown if the durations file or url does not work.",
    );

    option maybe_durations => (
        type => 's',

        long_examples  => [' file.json', ' http://example.com/durations.json'],
        short_examples => [' file.json', ' http://example.com/durations.json'],

        description => "Point at a json file or url which has a hash of relative test filenames as keys, and 'SHORT', 'MEDIUM', or 'LONG' as values. This will override durations listed in the file headers. An exception will be thrown if the durations file or url does not work.",
    );

    option durations_threshold => (
        alt => ['Dt'],
        type => 's',
        default => undef,
        description => "Only fetch duration data if running at least this number of tests. Default (-j value + 1)"
    );

    option exclude_file => (
        field => 'exclude_files',
        type  => 'm',

        long_examples  => [' t/nope.t'],
        short_examples => [' t/nope.t'],

        description => "Exclude a file from testing",
    );

    option exclude_pattern => (
        field => 'exclude_patterns',
        type  => 'm',

        long_examples  => [' t/nope.t'],
        short_examples => [' t/nope.t'],

        description => "Exclude a pattern from testing, matched using m/\$PATTERN/",
    );

    option exclude_list => (
        field => 'exclude_lists',
        type => 'm',

        long_examples  => [' file.txt', ' http://example.com/exclusions.txt'],
        short_examples => [' file.txt', ' http://example.com/exclusions.txt'],

        description => "Point at a file or url which has a new line separated list of test file names to exclude from testing. Starting a line with a '#' will comment it out (for compatibility with Test2::Aggregate list files).",
    );

    option default_search => (
        type => 'm',

        description => "Specify the default file/dir search. defaults to './t', './t2', and 'test.pl'. The default search is only used if no files were specified at the command line",
    );

    option default_at_search => (
        type => 'm',

        description => "Specify the default file/dir search when 'AUTHOR_TESTING' is set. Defaults to './xt'. The default AT search is only used if no files were specified at the command line",
    );

    post \&_post_process;
};

sub _post_process {
    my %params   = @_;
    my $settings = $params{settings};
    my $options  = $params{options};

    my $finder = $settings->finder;

    my $rerun = $finder->rerun;

    for my $mode (sort keys %RERUN_MODES) {
        my $val = $finder->remove_field("rerun_$mode") or next;

        push @{$finder->rerun_modes} => $mode;

        next if $val eq '1';

        $rerun //= $val;
        $rerun = $val if $rerun eq '1';

        die "Multiple runs specified for rerun ($val and $rerun). Please pick one.\n" if $val ne $rerun;
    }

    $finder->field(rerun => $rerun);

    my (%seen, @keep);
    for my $mode (sort map { split /,/ } @{$finder->rerun_modes}) {
        next if $seen{$mode}++;
        die "Invalid rerun-mode '$mode'.\n" unless $RERUN_MODES{$mode};
        push @keep => $mode;
    }
    push @keep => 'all' unless @keep;

    @{$finder->rerun_modes} = @keep;

    if (!defined($settings->finder->durations_threshold)) {
        if ($settings->check_prefix('runner')) {
            my $jc = $settings->runner->job_count // 1;
            $settings->finder->field(durations_threshold => $jc + 1);
        }

        $settings->finder->field(durations_threshold => 1);
    }

    $settings->finder->field(default_search => ['./t', './t2', 'test.pl'])
        unless $settings->finder->default_search && @{$settings->finder->default_search};

    $settings->finder->field(default_at_search => ['./xt'])
        unless $settings->finder->default_at_search && @{$settings->finder->default_at_search};

    @{$settings->finder->extensions} = ('t', 't2')
        unless @{$settings->finder->extensions};

    s/^\.//g for @{$settings->finder->extensions};
}

sub normalize_class {
    my ($class) = @_;

    $class = "Test2::Harness::Finder::$class"
        unless $class =~ s/^\+//;

    my $file = mod2file($class);
    require $file;

    return $class;
}

sub finder_pre_process {
    my %params = @_;

    my $class = $params{val} or return;

    $class = normalize_class($class);

    return unless $class->can('options');

    $params{options}->include_from($class);
}

sub finder_action {
    my ($prefix, $field, $raw, $norm, $slot, $settings, $handler, $options) = @_;

    my $class = $norm;

    $class = normalize_class($class);

    if ($class->can('options')) {
        $options->populate_pre_defaults();
        $options->populate_cmd_defaults();
    }

    $class->munge_settings($settings, $options) if $class->can('munge_settings');

    $handler->($slot, $class);
}

sub changes_applicable {
    my ($option, $options) = @_;

    # Cannot use this options with projects
    return 0 if $options->command_class && $options->command_class->isa('App::Yath::Command::projects');
    return 1;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Finder - Finder options for Yath.

=head1 DESCRIPTION

This is where the command line options for discovering test files are defined.

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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
