package App::Yath2::Options::Finder;
use strict;
use warnings;

our $VERSION = '2.000011';

use Test2::Harness2::Util qw/fqmod/;
use List::Util qw/first/;
use Getopt::Yath;

my %RERUN_MODES = (
    all     => "Re-Run all tests from a previous run from a log file (or last log file). Plugins can intercept this, such as the database plugin which will grab a run UUID and derive tests to re-run from that.",
    failed  => "Re-Run failed tests from a previous run from a log file (or last log file). Plugins can intercept this, such as the database plugin which will grab a run UUID and derive tests to re-run from that.",
    retried => "Re-Run retried tests from a previous run from a log file (or last log file). Plugins can intercept this, such as the database plugin which will grab a run UUID and derive tests to re-run from that.",
    passed  => "Re-Run passed tests from a previous run from a log file (or last log file). Plugins can intercept this, such as the database plugin which will grab a run UUID and derive tests to re-run from that.",
    missed  => "Run missed tests from a previously aborted/stopped run from a log file (or last log file). Plugins can intercept this, such as the database plugin which will grab a run UUID and derive tests to re-run from that.",
);

option_group {group => 'finder', category => "Finder Options"} => sub {
    # TODO: Stage 6 — activate --finder when alternative finders ship
    # option class => (
    #     name    => 'finder',
    #     field   => 'class',
    #     type    => 'Scalar',
    #     default => 'App::Yath2::Finder',
    #
    #     mod_adds_options => 1,
    #     long_examples    => [' MyFinder', ' +App::Yath2::Finder::MyFinder'],
    #     description      => 'Specify what Finder subclass to use when searching for files/processing the file list. Use the "+" prefix to specify a fully qualified namespace, otherwise App::Yath2::Finder::XXX namespace is assumed.',
    #
    #     normalize => sub { fqmod($_[0], 'App::Yath2::Finder') },
    # );

    option extensions => (
        type     => 'List',
        alt      => ['ext', 'extension'],
        split_on => ',',

        description => 'Specify valid test filename extensions, default: t and t2',
        normalize   => sub { $_[0] =~ s/^\.+//g; $_[0] },
        default     => sub { qw/t t2/ },
    );

    # TODO: Stage 6 — activate --no-long when finder is wired to the test command
    # option no_long => (
    #     type => 'Bool',
    #
    #     description => "Do not run tests that have their duration flag set to 'LONG'",
    # );

    # TODO: Stage 6 — activate --only-long when finder is wired to the test command
    # option only_long => (
    #     type => 'Bool',
    #
    #     description => "Only run tests that have their duration flag set to 'LONG'",
    # );

    # TODO: Stage 7 — activate --show-changed-files when changed-files plugin lands
    # option show_changed_files => (
    #     type => 'Bool',
    #
    #     description => "Print a list of changed files if any are found",
    # );

    # TODO: Stage 7 — activate --changed-only when changed-files plugin lands
    # option changed_only => (
    #     type => 'Bool',
    #
    #     description => "Only search for tests for changed files (Requires a coverage data source, also requires a list of changes either from the --changed option, or a plugin that implements changed_files() or changed_diff())",
    # );

    # TODO: Stage 11 — activate --rerun when archive/log scope returns
    # option rerun => (
    #     type => 'Auto',
    #
    #     description   => "Re-Run tests from a previous run from a log file (or last log file). Plugins can intercept this, such as the database plugin which will grab a run UUID and derive tests to re-run from that.",
    #     long_examples => ['', '=path/to/log.jsonl', '=plugin_specific_string'],
    #
    #     autofill => sub {
    #         my $log = first { -e $_ } qw{ ./lastlog.jsonl ./lastlog.jsonl.bz2 ./lastlog.jsonl.gz };
    #         return $log // -1;
    #     },
    # );

    # TODO: Stage 11 — activate --rerun-plugin when archive/log scope returns
    # option rerun_plugins => (
    #     type => 'List',
    #     alt => ['rerun-plugin'],
    #
    #     description   => "What plugin(s) should be used for rerun (will fallback to other plugins if the listed ones decline the value, this is just used to set an order of priority)",
    #     long_examples => [' Foo', ' +App::Yath2::Plugin::Foo'],
    #
    #     mod_adds_options => 1,
    #     normalize => sub { fqmod($_[0], 'App::Yath2::Plugin') },
    # );

    my $modes = join '|' => sort keys %RERUN_MODES;
    # TODO: Stage 11 — activate --rerun-MODE matrix when archive/log scope returns
    # option rerun_modes => (
    #     type => 'BoolMap',
    #
    #     default => sub { all => 1 },
    #
    #     pattern => qr/rerun-($modes)(=.+)?/,
    #
    #     long_examples => [' ' . join(',', sort keys %RERUN_MODES)],
    #
    #     requires_arg => 1,
    #
    #     normalize => sub {
    #         map { die "'$_' is not a valid run mode" unless $RERUN_MODES{$_}; $_ => 1 } split /[\s,]+/, $_[0];
    #     },
    #
    #     description => join(" " => "Pick which test categories to run.", map { sprintf("%-8s %s", "$_:", $RERUN_MODES{$_}) } sort keys %RERUN_MODES),
    #
    #     trigger => sub {
    #         my $opt = shift;
    #         my %params = @_;
    #         return unless $params{action} eq 'set';
    #         $params{settings}->finder->rerun(1) unless $params{settings}->finder->rerun;
    #     },
    #
    #     custom_matches => sub {
    #         my $opt = shift;
    #         my ($input, $state) = @_;
    #
    #         my $pattern = $opt->pattern;
    #
    #         return unless $input =~ $pattern;
    #
    #         my ($no, $key, $val) = ($1, $2, $3);
    #
    #         if ($val) {
    #             $val =~ s/^=//;
    #             $state->{settings}->finder->rerun($val);
    #         }
    #
    #         return ($opt, 1, [$key => $no ? 0 : 1]);
    #     },
    #
    #     notes => "This will turn on the 'rerun' option. If the --rerun-MODE form is used, you can specify the log file with --rerun-MODE=logfile.",
    # );

    # TODO: Stage 7 — activate --changed when changed-files plugin lands
    # option changed => (
    #     type          => 'PathList',
    #     split_on      => ',',
    #     description   => "Specify one or more files as having been changed.",
    #     long_examples => [' path/to/file'],
    # );

    # TODO: Stage 7 — activate --changes-exclude-file when changed-files plugin lands
    # option changes_exclude_files => (
    #     alt           => ['changes-exclude-file'],
    #     type          => 'PathList',
    #     split_on      => ',',
    #     description   => 'Specify one or more files to ignore when looking at changes',
    #     long_examples => [' path/to/file'],
    # );

    # TODO: Stage 7 — activate --changes-exclude-pattern when changed-files plugin lands
    # option changes_exclude_patterns => (
    #     alt           => ['changes-exclude-pattern'],
    #     type          => 'PathList',
    #     split_on      => ',',
    #     description   => 'Ignore files matching this pattern when looking for changes. Your pattern will be inserted unmodified into a `$file =~ m/$pattern/` check.',
    #     long_examples => [" '(apple|pear|orange)'"],
    # );

    # TODO: Stage 7 — activate --changes-filter-file when changed-files plugin lands
    # option changes_filter_files => (
    #     alt           => ['changes-filter-file'],
    #     type          => 'PathList',
    #     split_on      => ',',
    #     description   => 'Specify one or more files to check for changes. Changes to other files will be ignored',
    #     long_examples => [' path/to/file'],
    # );

    # TODO: Stage 7 — activate --changes-filter-pattern when changed-files plugin lands
    # option changes_filter_patterns => (
    #     alt           => ['changes-filter-pattern'],
    #     type          => 'List',
    #     split_on      => ',',
    #     description   => 'Specify a pattern for change checking. When only running tests for changed files this will limit which files are checked for changes. Only files that match this pattern will be checked. Your pattern will be inserted unmodified into a `$file =~ m/$pattern/` check.',
    #     long_examples => [" '(apple|pear|orange)'"],
    # );

    # TODO: Stage 7 — activate --changes-diff when changed-files plugin lands
    # option changes_diff => (
    #     type          => 'Scalar',
    #     description   => "Path to a diff file that should be used to find changed files for use with --changed-only. This must be in the same format as `git diff -W --minimal -U1000000`",
    #     long_examples => [' path/to/diff.diff'],
    # );

    # TODO: Stage 7 — activate --changes-plugin when changed-files plugin lands
    # option changes_plugin => (
    #     type => 'Scalar',
    #     description => "What plugin should be used to detect changed files.",
    #     long_examples => [' Git', ' +App::Yath2::Plugin::Git'],
    # );

    # TODO: Stage 7 — activate --changes-include-whitespace when changed-files plugin lands
    # option changes_include_whitespace => (
    #     type => 'Bool',
    #     description => "Include changed lines that are whitespace only (default: off)",
    #     default => 0,
    # );

    # TODO: Stage 7 — activate --changes-exclude-nonsub when changed-files plugin lands
    # option changes_exclude_nonsub => (
    #     type => 'Bool',
    #     description => "Exclude changes outside of subroutines (perl files only) (default: off)",
    #     default => 0,
    # );

    # TODO: Stage 7 — activate --changes-exclude-loads when changed-files plugin lands
    # option changes_exclude_loads => (
    #     type => 'Bool',
    #     description => "Exclude coverage tests which only load changed files, but never call code from them. (default: off)",
    #     default => 0,
    # );

    # TODO: Stage 7 — activate --changes-exclude-opens when changed-files plugin lands
    # option changes_exclude_opens => (
    #     type => 'Bool',
    #     description => "Exclude coverage tests which only open() changed files, but never call code from them. (default: off)",
    #     default => 0,
    # );

    # TODO: Stage 6 — activate --durations when finder durations support is wired
    # option durations => (
    #     type => 'Scalar',
    #
    #     long_examples  => [' file.json', ' http://example.com/durations.json'],
    #     short_examples => [' file.json', ' http://example.com/durations.json'],
    #
    #     description => "Point at a json file or url which has a hash of relative test filenames as keys, and 'SHORT', 'MEDIUM', or 'LONG' as values. This will override durations listed in the file headers. An exception will be thrown if the durations file or url does not work.",
    # );

    # TODO: Stage 6 — activate --maybe-durations when finder durations support is wired
    # option maybe_durations => (
    #     type => 'Scalar',
    #
    #     long_examples  => [' file.json', ' http://example.com/durations.json'],
    #     short_examples => [' file.json', ' http://example.com/durations.json'],
    #
    #     description => "Point at a json file or url which has a hash of relative test filenames as keys, and 'SHORT', 'MEDIUM', or 'LONG' as values. This will override durations listed in the file headers. An exception will be thrown if the durations file or url does not work.",
    # );

    # TODO: Stage 6 — activate --durations-threshold when finder durations support is wired
    # option durations_threshold => (
    #     type        => 'Scalar',
    #     alt         => ['Dt'],
    #     default     => 0,
    #     description => "Only fetch duration data if running at least this number of tests. Default: 0"
    # );

    # TODO: Stage 6 — activate --exclude-file when finder exclusion support is wired
    # option exclude_files => (
    #     alt => ['exclude-file'],
    #     type  => 'PathList',
    #     field => 'exclude-files',
    #
    #     long_examples  => [' t/nope.t'],
    #     short_examples => [' t/nope.t'],
    #
    #     description => "Exclude a file from testing",
    # );

    # TODO: Stage 6 — activate --exclude-pattern when finder exclusion support is wired
    # option exclude_patterns => (
    #     alt => ['exclude-pattern'],
    #     type  => 'List',
    #     field => 'exclude-patterns',
    #
    #     long_examples  => [' nope'],
    #     short_examples => [' nope'],
    #
    #     description => "Exclude a pattern from testing, matched using m/\$PATTERN/",
    # );

    # TODO: Stage 6 — activate --exclude-list when finder exclusion support is wired
    # option exclude_lists => (
    #     alt  => ['exclude-list'],
    #     type => 'PathList',
    #
    #     long_examples  => [' file.txt', ' http://example.com/exclusions.txt'],
    #     short_examples => [' file.txt', ' http://example.com/exclusions.txt'],
    #
    #     description => "Point at a file or url which has a new line separated list of test file names to exclude from testing. Starting a line with a '#' will comment it out (for compatibility with Test2::Aggregate list files).",
    # );

    # TODO: Stage 6 — activate --default-search when finder is wired to test command
    # option default_search => (
    #     type    => 'PathList',
    #     default => sub { './t', './t2', './test.pl' },
    #
    #     description => "Specify the default file/dir search. defaults to './t', './t2', and 'test.pl'. The default search is only used if no files were specified at the command line",
    # );

    # TODO: Stage 6 — activate --default-at-search when finder is wired to test command
    # option default_at_search => (
    #     type    => 'PathList',
    #     default => sub { './xt' },
    #
    #     description => "Specify the default file/dir search when 'AUTHOR_TESTING' is set. Defaults to './xt'. The default AT search is only used if no files were specified at the command line",
    # );
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Finder - FIXME

=head1 DESCRIPTION

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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

