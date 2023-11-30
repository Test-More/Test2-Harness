package App::Yath::Options::Runner;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Util qw/IS_WIN32/;

use Test2::Harness::Util qw/mod2file fqmod clean_path/;

use Getopt::Yath;

include_options(
    'App::Yath::Options::Tests',
);

option_group {group => 'runner', category => "Runner Options"} => sub {
    option preloads => (
        type  => 'List',
        alt   => ['preload'],
        short => 'P',

        description => 'Preload a module before running tests',
    );

    option preload_retry_delay => (
        type => 'Scalar',
        default => 5,
        description => "Time in seconds to wait before trying to load a preload/stage after a failed attempt",
    );

    option class => (
        name    => 'runner',
        field   => 'class',
        type    => 'Scalar',

        default => sub {
            my ($opt, $settings) = @_;

            return 'Test2::Harness::Runner' if IS_WIN32;
            return 'Test2::Harness::Runner::Preloading' if @{$settings->runner->preloads // []};
            return 'Test2::Harness::Runner';
        },

        mod_adds_options => 1,
        long_examples    => [' MyRunner', ' +Test2::Harness::Runner::MyRunner'],
        description      => 'Specify what Runner subclass to use. Use the "+" prefix to specify a fully qualified namespace, otherwise Test2::Harness::Runner::XXX namespace is assumed.',

        normalize => sub { fqmod($_[0], 'Test2::Harness::Runner') },
    );

    option dump_depmap => (
        type        => 'Bool',
        default     => 0,
        description => "When using staged preload, dump the depmap for each stage as json files",
    );

    option reloader => (
        type => 'Auto',
        alt => ['reload'],
        autofill => 'Test2::Harness::Reloader',
        normalize => sub { fqmod($_[0], 'Test2::Harness::Reloader') },

        description => "Use a reloader (default Test2::Harness::Reloader) to reload modules in place. This is discouraged as there are too many gotchas",
    );

    option restrict_reload => (
        type => 'AutoList',
        normalize => sub { clean_path($_[0]) },
        autofill => sub {
            my ($opt, $settings) = @_;

            require Test2::Harness::TestSettings;
            my $ts = Test2::Harness::TestSettings->new($settings->tests->all);

            return map { clean_path($_) } @{$ts->includes};
        },
    );
};

option_post_process \&runner_post_process;

sub runner_post_process {
    my ($options, $state) = @_;

    my $settings = $state->{settings};
    my $runner   = $settings->runner;
    my $tests    = $settings->tests;

    warn "WARNING: Combining preload and switches will render preloads useless...\n"
        if @{$runner->preloads // []} && @{$tests->switches // []};
};
