package App::Yath::Command::test;
use strict;
use warnings;

our $VERSION = '2.000000';

use Time::HiRes qw/sleep/;
use Test2::Harness::Util qw/mod2file write_file_atomic/;
use Test2::Harness::Util::JSON qw/encode_json/;

use parent 'App::Yath::Command::run';
use Test2::Harness::Util::HashBase qw{
    +plugins
};

use Getopt::Yath;
include_options(
    'App::Yath::Options::Finder',
    'App::Yath::Options::IPC',
    'App::Yath::Options::Harness',
    'App::Yath::Options::Renderer',
    'App::Yath::Options::Resource',
    'App::Yath::Options::Run',
    'App::Yath::Options::Runner',
    'App::Yath::Options::Scheduler',
    'App::Yath::Options::Tests',
    'App::Yath::Options::Yath',
    'App::Yath::Options::Interactive',
);

    option preload_threshold => (
        type    => 'Scalar',
        short   => 'W',
        alt     => ['Pt'],
        default => 0,

        description => "Only do preload if at least N tests are going to be run. In some cases a full preload takes longer than simply running the tests, this lets you specify a minimum number of test jobs that will be run for preload to happen. The default is 0, and it means always preload."
    );

sub starts_runner      { 1 }
sub args_include_tests { 1 }

sub group { ' test' }

sub summary  { "Run tests" }

sub description {
    return <<"    EOT";
This yath command will run all the test files for the current project. If no test files are specified this command will look for the 't', and 't2' directories, as well as the 'test.pl' file.

This command is always recursive when given directories.

This command will add 'lib', 'blib/arch' and 'blib/lib' to the perl path for you by default (after any -I's). You can specify -l if you just want lib, -b if you just want the blib paths. If you specify both -l and -b both will be added in the order you specify (order relative to any -I options will also be preserved.  If you do not specify they will be added in this order: -I's, lib, blib/lib, blib/arch. You can also add --no-lib and --no-blib to avoid both.

Any command line argument that is not an option will be treated as a test file or directory of test files to be run.

If you wish to specify the ARGV for tests you may append them after '::'. This is mainly useful for Test::Class::Moose and similar tools. EVERY test executed will get the same ARGV.
    EOT
}

sub run {
    my $self = shift;

    warn "Fix this";
    $0 = "yath-test";

    my $settings = $self->settings;

    # Get list of tests to run
    my $tests = $self->find_tests;

    if (!$tests || !@$tests) {
        print "Nothing to do, no tests to run!\n";
        return 0;
    }

    my $workdir = $settings->harness->workdir;

    my $settings_file = File::Spec->catfile($workdir, 'settings.json');
    write_file_atomic($settings_file, encode_json($settings));

    my @start_command = (
        $^X,
        (map { "-I$_" } @{$settings->yath->dev_libs}),
        $settings->yath->script,
        "--load-settings=$settings_file",
        'start'
    );

    system(@start_command);

    $self->SUPER::run();

    # Tell it to terminate!
}

1;
