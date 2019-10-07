package App::Yath::Command::test;
use strict;
use warnings;

our $VERSION = '0.001100';

use App::Yath::Options;

use Test2::Harness::Run;
use Test2::Harness::Util::Queue;
use Test2::Harness::Util::File::JSON;
use Test2::Harness::IPC;

use File::Spec;

use Carp qw/croak/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw/<runner_pid <harness_pid <ipc/;

include_options(
    'App::Yath::Options::Debug',
    'App::Yath::Options::Display',
    'App::Yath::Options::Logging',
    'App::Yath::Options::PreCommand',
    'App::Yath::Options::Run',
    'App::Yath::Options::Runner',
    'App::Yath::Options::Workspace',
);

sub MAX_ATTACH() { 1_048_576 }

sub group { ' test' }

sub summary  { "Run tests" }
sub cli_args { "[--] [test files/dirs] [::] [arguments to test scripts]" }

sub description {
    return <<"    EOT";
This yath command (which is also the default command) will run all the test
files for the current project. If no test files are specified this command will
look for the 't', and 't2' dirctories, as well as the 'test.pl' file.

This command is always recursive when given directories.

This command will add 'lib', 'blib/arch' and 'blib/lib' to the perl path for
you by default.

Any command line argument that is not an option will be treated as a test file
or directory of test files to be run.

If you wish to specify the ARGV for tests you may append them after '::'. This
is mainly useful for Test::Class::Moose and similar tools. EVERY test run will
get the same ARGV.
    EOT
}

sub run {
    my $self = shift;

    $self->parse_args;

    my $settings = $self->settings;
    my $dir = $settings->workspace->workdir;
    print "DIR: $dir\n";

    $self->write_settings_to($dir, 'settings.json');

    my $ipc = $self->{+IPC} //= Test2::Harness::IPC->new;
    $ipc->start();

    my $run = $self->build_run();
    my $runner_proc = $self->start_runner();

#    # Start a collector
#    my $collector_proc = $self->start_collector($run, $runner_proc->pid);

#    # Start an auditor
#    my $auditor_proc = Test2::Harness::Process->new(
#        command => [
#            $^X, $settings->yath->script,
#            (map { "-D$_" } @{$settings->yath->dev_libs}),
#            auditor => 'Test2::Harness::Auditor',
#            $dir => $run->run_id,
#        ],
#    );

    # render results from log

    $ipc->wait(all => 1);
    $ipc->stop;

    system('cat', File::Spec->catfile($dir, 'output.log'));
    system('cat', File::Spec->catfile($dir, 'error.log'));
    print "\n";

    opendir(my $root, $dir);
    for my $run_dir (sort readdir($root)) {
        next if $run_dir =~ m/^\./;
        $run_dir = "$dir/$run_dir";
        next unless -d $run_dir;
        opendir(my $rh, $run_dir);
        for my $job_dir (sort readdir($rh)) {
            next if $job_dir =~ m/^\./;
            $job_dir = "$run_dir/$job_dir";
            next unless -d $job_dir;

            use Test2::Harness::Util qw/read_file/;

            my $term = read_file("$job_dir/exit");
            my ($exit, $code, $sig, $dmp, $stop, $retry) = split /\s+/, $term;

            print "$job_dir\n";
            print "File: " . read_file("$job_dir/file") . "\n";
            print "  Start: " . read_file("$job_dir/start") . "\n";
            print "  Stop:  $stop\n";
            print "  Exit:  $exit\n";
            print "  Code:  $code\n";
            print "   Sig:  $sig\n";
            print "  Dump:  $dmp\n";
            print " Retry:  " . ($retry ? 'Yes' : 'No') . "\n";

            for my $line (split /\n/, read_file("$job_dir/stderr")) {
                next if $line =~ m/T2-HARNESS-ESYNC/;
                print "STDERR: $line\n";
            }
            for my $line (split /\n/, read_file("$job_dir/stdout")) {
                next if $line =~ m/T2-HARNESS-ESYNC/;
                print "STDOUT: $line\n";
            }

            print "-------------------\n\n";
        }
    }

    #system('for i in '. $dir .'/*/*/; do cat $i/file; echo; echo -n "  START (time):  "; cat $i/start; echo; echo -n "  EXIT (err sig time retry): "; cat $i/exit; echo; echo; done');
    print "DIR: $dir\n";

    return 0;
}

sub start_collector {
    my $self = shift;
    my ($run, $runner_pid) = @_;

    my $settings = $self->settings;
    my $dir = $settings->workspace->workdir;

    my $collector_proc = Test2::Harness::Process->new(
        command => [
            $^X, $settings->yath->script,
            (map { "-D$_" } @{$settings->yath->dev_libs}),
            collector => 'Test2::Harness::Collector',
            $dir, $run->run_id, $runner_pid,
            show_runner_output => 1,
        ],
    );
    $collector_proc->start;

    return $collector_proc;
}

sub start_runner {
    my $self = shift;

    my $settings = $self->settings;
    my $dir = $settings->workspace->workdir;

    my $ipc = $self->ipc;
    $ipc->spawn(
        #stderr => File::Spec->catfile($dir, 'error.log'),
        #stdout => File::Spec->catfile($dir, 'output.log'),
        no_set_pgrp => 1,
        command => [
            $^X, $settings->yath->script,
            (map { "-D$_" } @{$settings->yath->dev_libs}),
            runner => $dir,
        ],
    );
}

sub build_run {
    my $self = shift;

    my $settings = $self->settings;
    my $dir = $settings->workspace->workdir;

    my $run = $settings->build(run => 'Test2::Harness::Run');
    $run->write_queue($dir, $settings->yath->plugins);

    my $run_queue = Test2::Harness::Util::Queue->new(file => File::Spec->catfile($dir, 'run_queue.jsonl'));
    $run_queue->start();
    $run_queue->enqueue($run->queue_item($settings->yath->plugins));
    $run_queue->end;

    return $run;
}

sub parse_args {
    my $self = shift;
    my $settings = $self->settings;
    my $args = $self->args;

    my $dest = $settings->run->search;
    for my $arg (@$args) {
        next if $arg eq '--';
        if ($arg eq '::') {
            $dest = $settings->run->test_args;
            next;
        }

        push @$dest => $arg;
    }

    return;
}

sub write_settings_to {
    my $self = shift;
    my ($dir, $file) = @_;

    croak "'directory' is a required parameter" unless $dir;
    croak "'filename' is a required parameter" unless $file;

    my $settings = $self->settings;
    my $settings_file = Test2::Harness::Util::File::JSON->new(name => File::Spec->catfile($dir, $file));
    $settings_file->write($settings);
    return $settings_file->name;
}

1;
