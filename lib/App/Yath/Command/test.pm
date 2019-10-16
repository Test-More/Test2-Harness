package App::Yath::Command::test;
use strict;
use warnings;

our $VERSION = '0.001100';

use App::Yath::Options;

use Test2::Harness::Run;
use Test2::Harness::Util::Queue;
use Test2::Harness::Util::File::JSON;
use Test2::Harness::IPC;

use Test2::Harness::Runner::State;

use Test2::Harness::Util::JSON qw/encode_json decode_json/;
use Test2::Harness::Util qw/mod2file open_file/;
use Test2::Util::Table qw/table/;

use File::Spec;

use Carp qw/croak/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw/
    <runner_pid <ipc

    +run

    +auditor_reader
    +collector_writer
    +renderer_reader
    +auditor_writer

    +renderers
    +logger

    +run_queue
/;

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

sub auditor_reader {
    my $self = shift;
    return $self->{+AUDITOR_READER} if $self->{+AUDITOR_READER};
    pipe($self->{+AUDITOR_READER}, $self->{+COLLECTOR_WRITER}) or die "Could not create pipe: $!";
    return $self->{+AUDITOR_READER};
}

sub collector_writer {
    my $self = shift;
    return $self->{+COLLECTOR_WRITER} if $self->{+COLLECTOR_WRITER};
    pipe($self->{+AUDITOR_READER}, $self->{+COLLECTOR_WRITER}) or die "Could not create pipe: $!";
    return $self->{+COLLECTOR_WRITER};
}

sub renderer_reader {
    my $self = shift;
    return $self->{+RENDERER_READER} if $self->{+RENDERER_READER};
    pipe($self->{+RENDERER_READER}, $self->{+AUDITOR_WRITER}) or die "Could not create pipe: $!";
    return $self->{+RENDERER_READER};
}

sub auditor_writer {
    my $self = shift;
    return $self->{+AUDITOR_WRITER} if $self->{+AUDITOR_WRITER};
    pipe($self->{+RENDERER_READER}, $self->{+AUDITOR_WRITER}) or die "Could not create pipe: $!";
    return $self->{+AUDITOR_WRITER};
}

sub workdir {
    my $self = shift;
    $self->settings->workspace->workdir;
}

sub run {
    my $self = shift;

    $self->parse_args;

    my $settings = $self->settings;
    my $dir = $self->workdir();

    $self->write_settings_to($dir, 'settings.json');

    my $ipc = $self->{+IPC} //= Test2::Harness::IPC->new;
    $ipc->start();

    my $run = $self->build_run();

    $self->populate_queue($run);

    my $runner_proc    = $self->start_runner(monitor_preloads => 0);
    my $collector_proc = $self->start_collector($run, $runner_proc->pid);
    my $auditor_proc   = $self->start_auditor($run);

    my $renderers = $self->renderers;
    my $logger    = $self->logger;

    # render results from log
    my $reader = $self->renderer_reader();
    while (my $line = <$reader>) {
        print $logger $line if $logger;
        my $e = decode_json($line);
        last unless defined $e;

        $_->render_event($e) for @$renderers;

        $ipc->wait();
    }
    close($logger) if $logger;

    $_->finish() for @$renderers;

    my $final_data = decode_json(scalar <$reader>);
    $self->render_final_data($final_data);

    $ipc->wait(all => 1);
    $ipc->stop;

    printf("\nKeeping work dir: %s\n", $dir) if $settings->debug->keep_dirs;

    print "\nWrote log file: " . $settings->logging->log_file . "\n"
        if $settings->logging->log;

    return $final_data->{pass} ? 0 : 1;
}

sub populate_queue {
    my $self = shift;
    my ($run) = @_;

    my $state = Test2::Harness::Runner::State->new(workdir => $self->workdir, job_count => 1);

    my $plugins = $self->settings->yath->plugins;

    $state->queue_run($run->queue_item($plugins));

    my $tasks_queue = Test2::Harness::Util::Queue->new(file => File::Spec->catfile($run->run_dir($self->workdir), 'queue.jsonl'));

    my $job_count = 0;
    for my $file ( @{$run->find_files($plugins)} ) {
        my $task = $file->queue_item(++$job_count, $run->run_id);
        $state->queue_task($task);
        $tasks_queue->enqueue($task);
    }

    $tasks_queue->end();
    $state->end_queue();
}

sub render_final_data {
    my $self = shift;
    my ($final_data) = @_;

    if (my $rows = $final_data->{retried}) {
        print "\nThe following jobs failed at least once:\n";
        print join "\n" => table(
            header => ['Job ID', 'Times Run', 'Test File', "Succeded Eventually?"],
            rows   => $rows,
        );
        print "\n";
    }

    if (my $rows = $final_data->{failed}) {
        print "\nThe following jobs failed:\n";
        print join "\n" => table(
            header => ['Job ID', 'Test File'],
            rows   => $rows,
        );
        print "\n";
    }

    if (my $rows = $final_data->{unseen}) {
        print "\nThe following jobs never ran:\n";
        print join "\n" => table(
            header => ['Job ID', 'Test File'],
            rows   => $rows,
        );
        print "\n";
    }
}

sub logger {
    my $self = shift;

    return $self->{+LOGGER} if $self->{+LOGGER};

    my $settings = $self->{+SETTINGS};

    return unless $settings->logging->log;

    my $file = $settings->logging->log_file;

    if ($settings->logging->bzip2) {
        require IO::Compress::Bzip2;
        $self->{+LOGGER} = IO::Compress::Bzip2->new($file) or die "Could not open log file '$file': $IO::Compress::Bzip2::Bzip2Error";
        return $self->{+LOGGER};
    }
    elsif ($settings->logging->gzip) {
        require IO::Compress::Gzip;
        $self->{+LOGGER} = IO::Compress::Gzip->new($file) or die "Could not open log file '$file': $IO::Compress::Gzip::GzipError";
        return $self->{+LOGGER};
    }

    return $self->{+LOGGER} = open_file($file, '>');
}

sub renderers {
    my $self = shift;

    return $self->{+RENDERERS} if $self->{+RENDERERS};

    my $settings = $self->{+SETTINGS};

    my @renderers;
    for my $class (@{$settings->display->renderers->{'@'}}) {
        require(mod2file($class));
        my $args     = $settings->display->renderers->{$class};
        my $renderer = $class->new(@$args, settings => $settings);
        push @renderers => $renderer;
    }

    return $self->{+RENDERERS} = \@renderers;
}

sub start_auditor {
    my $self = shift;
    my ($run) = @_;

    my $settings = $self->settings;

    my $ipc = $self->ipc;
    $ipc->spawn(
        stdin       => $self->auditor_reader(),
        stdout      => $self->auditor_writer(),
        no_set_pgrp => 1,
        command     => [
            $^X, $settings->yath->script,
            (map { "-D$_" } @{$settings->yath->dev_libs}),
            '--no-scan-plugins',    # Do not preload any plugin modules
            auditor => 'Test2::Harness::Auditor',
            $run->run_id,
        ],
    );

    close($self->auditor_writer());
}

sub start_collector {
    my $self = shift;
    my ($run, $runner_pid) = @_;

    my $settings = $self->settings;
    my $dir = $self->workdir;

    my ($rh, $wh);
    pipe($rh, $wh) or die "Could not create pipe";

    my $ipc = $self->ipc;
    $ipc->spawn(
        stdout      => $self->collector_writer,
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

    close($self->collector_writer());
}

sub start_runner {
    my $self = shift;
    my %args = @_;

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
            %args,
        ],
    );
}

sub run_queue {
    my $self = shift;
    my $dir = $self->workdir;
    return $self->{+RUN_QUEUE} //= Test2::Harness::Util::Queue->new(file => File::Spec->catfile($dir, 'run_queue.jsonl'));
}

sub build_run {
    my $self = shift;

    return $self->{+RUN} if $self->{+RUN};

    my $settings = $self->settings;
    my $dir = $self->workdir;

    my $run = $settings->build(run => 'Test2::Harness::Run');

    mkdir($run->run_dir($dir)) or die "Could not make run dir: $!";

    return $self->{+RUN} = $run;
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

1;
