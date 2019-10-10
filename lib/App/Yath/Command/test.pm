package App::Yath::Command::test;
use strict;
use warnings;

our $VERSION = '0.001100';

use App::Yath::Options;

use Test2::Harness::Run;
use Test2::Harness::Util::Queue;
use Test2::Harness::Util::File::JSON;
use Test2::Harness::IPC;


use Test2::Harness::Util::JSON qw/encode_json decode_json/;
use Test2::Harness::Util qw/mod2file/;

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

    $self->write_settings_to($dir, 'settings.json');

    my $ipc = $self->{+IPC} //= Test2::Harness::IPC->new;
    $ipc->start();

    my $run = $self->build_run();
    my $runner_proc = $self->start_runner();

    my ($auditor_read, $collector_write);
    pipe($auditor_read, $collector_write) or die "Could not make a pipe: $!";

    # Start a collector
    my $collector_proc = $self->start_collector($run, $runner_proc->pid, $collector_write);
    close($collector_write);

    my ($renderer_read, $auditor_write);
    if ($settings->logging->log) {
        open($auditor_write, '>', $settings->logging->log_file) or die "Could not open log file for writing: $!";
        open($renderer_read, '<', $settings->logging->log_file) or die "Could not open log file for reading: $!";
    }
    else {
        pipe($renderer_read, $auditor_write) or die "Could not make pipe: $!";
    }

    my $auditor_proc = $self->start_auditor($run, $auditor_read, $auditor_write);
    close($auditor_read);
    close($auditor_write);

    my @renderers;
    for my $class (@{$settings->display->renderers->{'@'}}) {
        require(mod2file($class));
        my $args = $settings->display->renderers->{$class};
        my $renderer = $class->new(@$args, settings => $settings);
        push @renderers => $renderer;
    }

    # render results from log
    while (my $line = <$renderer_read>) {
        my $event = decode_json($line);
        last unless defined $event;

        $_->render_event($event) for @renderers;
    }

    $_->finish() for @renderers;

    my $final_data = decode_json(<$renderer_read>);
    use Data::Dumper;
    print Dumper($final_data);

    $ipc->wait(all => 1);
    $ipc->stop;

    print "DIR: $dir\n";

    return 0;
}

sub start_auditor {
    my $self = shift;
    my ($run, $stdin, $stdout) = @_;

    my $settings = $self->settings;

    my $ipc = $self->ipc;
    $ipc->spawn(
        stdin       => $stdin,
        stdout      => $stdout,
        no_set_pgrp => 1,
        command     => [
            $^X, $settings->yath->script,
            (map { "-D$_" } @{$settings->yath->dev_libs}),
            '--no-scan-plugins',    # Do not preload any plugin modules
            auditor => 'Test2::Harness::Auditor',
            $run->run_id,
        ],
    );
}

sub start_collector {
    my $self = shift;
    my ($run, $runner_pid, $stdout) = @_;

    my $settings = $self->settings;
    my $dir = $settings->workspace->workdir;

    my ($rh, $wh);
    pipe($rh, $wh) or die "Could not create pipe";

    my $ipc = $self->ipc;
    $ipc->spawn(
        stdout      => $stdout,
        stdin       => $rh,
        no_set_pgrp => 1,
        command     => [
            $^X, $settings->yath->script,
            (map { "-D$_" } @{$settings->yath->dev_libs}),
            '--no-scan-plugins',    # Do not preload any plugin modules
            collector => 'Test2::Harness::Collector',
            $dir, $run->run_id, $runner_pid,
            show_runner_output => 1,
        ],
    );

    close($rh);
    print $wh encode_json($run) . "\n";
    close($wh);
}

sub start_runner {
    my $self = shift;

    my $settings = $self->settings;
    my $dir = $settings->workspace->workdir;

    my $ipc = $self->ipc;
    $ipc->spawn(
        stderr => File::Spec->catfile($dir, 'error.log'),
        stdout => File::Spec->catfile($dir, 'output.log'),
        no_set_pgrp => 1,
        command => [
            $^X, $settings->yath->script,
            (map { "-D$_" } @{$settings->yath->dev_libs}),
            '--no-scan-plugins', # Do not preload any plugin modules
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
