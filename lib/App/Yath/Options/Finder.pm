package App::Yath::Options::Finder;
use strict;
use warnings;

our $VERSION = '1.000042';

use Test2::Harness::Util qw/mod2file/;

use App::Yath::Options;

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
        description => "Only search for tests for changed files (Requires --coverage-from, also requires a list of changes either from the --changed option, or a plugin that implements changed_files())",
        applicable => \&changes_applicable,
    );

    option changed => (
        type => 'm',
        description => "Specify one or more files as having been changed.",
        long_examples => [' path/to/file'],
        applicable => \&changes_applicable,
    );

    option changes_plugin => (
        type => 's',
        description => "What plugin should be used to detect changed files.",
        long_examples => [' Git', ' +App::Yath::Plugin::Git'],
        applicable => \&changes_applicable,
    );

    option coverage_from => (
        type => 's',
        description => "Where to fetch coverage data. Can be a path to a .jsonl(.bz|.gz)? log file. Can be a path or url to a json file containing a hash where source files are key, and value is a list of tests to run.",
        long_examples => [' path/to/log.jsonl', ' http://example.com/coverage', ' path/to/coverage.json']
    );

    option maybe_coverage_from => (
        type => 's',
        description => "Where to fetch coverage data. Can be a path to a .jsonl(.bz|.gz)? log file. Can be a path or url to a json file containing a hash where source files are key, and value is a list of tests to run.",
        long_examples => [' path/to/log.jsonl', ' http://example.com/coverage', ' path/to/coverage.json']
    );

    option coverage_url_use_post => (
        description => 'If coverage_from is a url, use the http POST method with a list of changed files. This allows the server to tell us what tests to run instead of downloading all the coverage data and determining what tests to run from that.',
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

    $settings->finder->field(default_search => ['./t', './t2', 'test.pl'])
        unless $settings->finder->default_search && @{$settings->finder->default_search};

    $settings->finder->field(default_at_search => ['./xt'])
        unless $settings->finder->default_at_search && @{$settings->finder->default_at_search};

    @{$settings->finder->extensions} = ('t', 't2')
        unless @{$settings->finder->extensions};

    s/^\.//g for @{$settings->finder->extensions};

    unless ($options->command_class && $options->command_class->isa('App::Yath::Command::projects')) {
        die "--changed-only, --changed, and --changes-plugin require --coverage_from or --maybe-coverage-from.\n"
            if $settings->finder->changed_only
            && !($settings->finder->coverage_from || $settings->finder->maybe_coverage_from);
    }
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
