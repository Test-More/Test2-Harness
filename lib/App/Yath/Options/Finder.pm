package App::Yath::Options::Finder;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Harness::Util qw/fqmod/;
use Getopt::Yath;

my %RERUN_MODES = (
    all     => "Re-Run all tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that.",
    failed  => "Re-Run failed tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that.",
    retried => "Re-Run retried tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that.",
    passed  => "Re-Run passed tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that.",
    missed  => "Run missed tests from a previously aborted/stopped run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that.",
);

option_group {group => 'finder', category => "Finder Options"} => sub {
    option class => (
        name    => 'finder',
        field   => 'class',
        type    => 'Scalar',
        default => 'App::Yath::Finder',

        mod_adds_options => 1,
        long_examples    => [' MyFinder', ' +App::Yath::Finder::MyFinder'],
        description      => 'Specify what Finder subclass to use when searching for files/processing the file list. Use the "+" prefix to specify a fully qualified namespace, otherwise App::Yath::Finder::XXX namespace is assumed.',

        normalize => sub { fqmod($_[0], 'App::Yath::Finder') },
    );

    option extensions => (
        type => 'List',
        alt  => ['ext', 'extension'],
        split_on => ',',

        description => 'Specify valid test filename extensions, default: t and t2',
        normalize   => sub { $_[0] =~ s/^\.+//g; $_[0] },
        default     => sub { qw/t t2/ },
    );

    option no_long => (
        type => 'Bool',

        description => "Do not run tests that have their duration flag set to 'LONG'",
    );

    option only_long => (
        type => 'Bool',

        description => "Only run tests that have their duration flag set to 'LONG'",
    );

    option show_changed_files => (
        type => 'Bool',

        description => "Print a list of changed files if any are found",
    );

    option changed_only => (
        type => 'Bool',

        description => "Only search for tests for changed files (Requires a coverage data source, also requires a list of changes either from the --changed option, or a plugin that implements changed_files() or changed_diff())",
    );

    option rerun => (
        type => 'Auto',

        description   => "Re-Run tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that.",
        long_examples => ['', '=path/to/log.jsonl', '=plugin_specific_string'],

        autofill => sub {
            my $log = first { -e $_ } qw{ ./lastlog.jsonl ./lastlog.jsonl.bz2 ./lastlog.jsonl.gz };
            return $log // './lastlog.jsonl';
        },
    );

    option rerun_plugins => (
        type => 'List',
        alt => ['rerun_plugin'],

        description   => "What plugin(s) should be used for rerun (will fallback to other plugins if the listed ones decline the value, this is just used to set an order of priority)",
        long_examples => [' Foo', ' +App::Yath::Plugin::Foo'],

        mod_adds_options => 1,
        normalize => sub { fqmod($_[0], 'App::Yath::Plugin') },
    );

    my $modes = join '|' => sort keys %RERUN_MODES;
    option rerun_modes => (
        type => 'BoolMap',

        default => sub { all => 1 },

        pattern => qr/rerun-($modes)(=.+)?/,

        long_examples => [' ' . join(',', sort keys %RERUN_MODES)],

        requires_arg => 1,

        normalize => sub {
            map { die "'$_' is not a valid run mode" unless $RERUN_MODES{$_}; $_ => 1 } split /[\s,]+/, $_[0];
        },

        description => ["Pick which test categories to run.", map { sprintf("%-8s %s", "$_:", $RERUN_MODES{$_}) } sort keys %RERUN_MODES],

        trigger => sub {
            my $opt = shift;
            my %params = @_;
            return unless $params{action} eq 'set';
            $params{settings}->finder->rerun(1) unless $params{settings}->finder->rerun;
        },

        custom_matches => sub {
            my $opt = shift;
            my ($input, $state) = @_;

            my $pattern = $opt->pattern;

            return unless $input =~ $pattern;

            my ($no, $key, $val) = ($1, $2, $3);

            if ($val) {
                $val =~ s/^=//;
                $state->{settings}->finder->rerun($val);
            }

            return ($opt, 1, [$key => $no ? 0 : 1]);
        },

        notes => "This will turn on the 'rerun' option. If the --rerun-MODE form is used, you can specify the log file with --rerun-MODE=logfile.",
    );

    option changed => (
        type          => 'List',
        split_on      => ',',
        description   => "Specify one or more files as having been changed.",
        long_examples => [' path/to/file'],
    );

    option changes_exclude_files => (
        alt           => ['changes_exclude_file'],
        type          => 'List',
        split_on      => ',',
        description   => 'Specify one or more files to ignore when looking at changes',
        long_examples => [' path/to/file'],
    );

    option changes_exclude_patterns => (
        alt           => ['changes_exclude_pattern'],
        type          => 'List',
        split_on      => ',',
        description   => 'Ignore files matching this pattern when looking for changes. Your pattern will be inserted unmodified into a `$file =~ m/$pattern/` check.',
        long_examples => [" '(apple|pear|orange)'"],
    );

    option changes_filter_files => (
        alt           => ['changes_filter_file'],
        type          => 'List',
        split_on      => ',',
        description   => 'Specify one or more files to check for changes. Changes to other files will be ignored',
        long_examples => [' path/to/file'],
    );

    option changes_filter_patterns => (
        alt           => ['changes_filter_pattern'],
        type          => 'List',
        split_on      => ',',
        description   => 'Specify a pattern for change checking. When only running tests for changed files this will limit which files are checked for changes. Only files that match this pattern will be checked. Your pattern will be inserted unmodified into a `$file =~ m/$pattern/` check.',
        long_examples => [" '(apple|pear|orange)'"],
    );

    option changes_diff => (
        type          => 'Scalar',
        description   => "Path to a diff file that should be used to find changed files for use with --changed-only. This must be in the same format as `git diff -W --minimal -U1000000`",
        long_examples => [' path/to/diff.diff'],
    );

    option changes_plugin => (
        type => 'Scalar',
        description => "What plugin should be used to detect changed files.",
        long_examples => [' Git', ' +App::Yath::Plugin::Git'],
    );

    option changes_include_whitespace => (
        type => 'Bool',
        description => "Include changed lines that are whitespace only (default: off)",
        default => 0,
    );

    option changes_exclude_nonsub => (
        type => 'Bool',
        description => "Exclude changes outside of subroutines (perl files only) (default: off)",
        default => 0,
    );

    option changes_exclude_loads => (
        type => 'Bool',
        description => "Exclude coverage tests which only load changed files, but never call code from them. (default: off)",
        default => 0,
    );

    option changes_exclude_opens => (
        type => 'Bool',
        description => "Exclude coverage tests which only open() changed files, but never call code from them. (default: off)",
        default => 0,
    );

    option durations => (
        type => 'Scalar',

        long_examples  => [' file.json', ' http://example.com/durations.json'],
        short_examples => [' file.json', ' http://example.com/durations.json'],

        description => "Point at a json file or url which has a hash of relative test filenames as keys, and 'SHORT', 'MEDIUM', or 'LONG' as values. This will override durations listed in the file headers. An exception will be thrown if the durations file or url does not work.",
    );

    option maybe_durations => (
        type => 'Scalar',

        long_examples  => [' file.json', ' http://example.com/durations.json'],
        short_examples => [' file.json', ' http://example.com/durations.json'],

        description => "Point at a json file or url which has a hash of relative test filenames as keys, and 'SHORT', 'MEDIUM', or 'LONG' as values. This will override durations listed in the file headers. An exception will be thrown if the durations file or url does not work.",
    );

    option durations_threshold => (
        type        => 'Scalar',
        alt         => ['Dt'],
        default     => 0,
        description => "Only fetch duration data if running at least this number of tests. Default: 0"
    );

    option exclude_files => (
        alt => ['exclude_file'],
        type  => 'List',
        field => 'exclude_files',

        long_examples  => [' t/nope.t'],
        short_examples => [' t/nope.t'],

        description => "Exclude a file from testing",
    );

    option exclude_patterns => (
        alt => ['exclude_pattern'],
        type  => 'List',
        field => 'exclude_patterns',

        long_examples  => [' t/nope.t'],
        short_examples => [' t/nope.t'],

        description => "Exclude a pattern from testing, matched using m/\$PATTERN/",
    );

    option exclude_lists => (
        alt  => ['exclude_list'],
        type => 'List',

        long_examples  => [' file.txt', ' http://example.com/exclusions.txt'],
        short_examples => [' file.txt', ' http://example.com/exclusions.txt'],

        description => "Point at a file or url which has a new line separated list of test file names to exclude from testing. Starting a line with a '#' will comment it out (for compatibility with Test2::Aggregate list files).",
    );

    option default_search => (
        type    => 'List',
        default => sub { './t', './t2', './test.pl' },

        description => "Specify the default file/dir search. defaults to './t', './t2', and 'test.pl'. The default search is only used if no files were specified at the command line",
    );

    option default_at_search => (
        type    => 'List',
        default => sub { './xt' },

        description => "Specify the default file/dir search when 'AUTHOR_TESTING' is set. Defaults to './xt'. The default AT search is only used if no files were specified at the command line",
    );
};

1;
