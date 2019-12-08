package App::Yath::Command::test;
use strict;
use warnings;

our $VERSION = '1.000000';

use App::Yath::Options;

use Test2::Harness::Run;
use Test2::Harness::Event;
use Test2::Harness::Util::Queue;
use Test2::Harness::Util::File::JSON;
use Test2::Harness::IPC;

use Test2::Harness::Runner::State;

use Test2::Harness::Util::JSON qw/encode_json decode_json/;
use Test2::Harness::Util qw/mod2file open_file/;
use Test2::Util::Table qw/table/;

use File::Spec;

use Time::HiRes qw/sleep time/;
use List::Util qw/sum max/;
use Carp qw/croak/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw/
    <runner_pid +ipc

    +run

    +auditor_reader
    +collector_writer
    +renderer_reader
    +auditor_writer

    +renderers
    +logger

    +tests_seen
    +asserts_seen

    +run_queue
    +tasks_queue
    +state

    <final_data
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

sub cover {
    return unless $ENV{T2_DEVEL_COVER};
    return unless $ENV{T2_COVER_SELF};
    return '-MDevel::Cover=-silent,1,+ignore,^t/,+ignore,^t2/,+ignore,^xt,+ignore,^test.pl';
}


sub init {
    my $self = shift;
    $self->SUPER::init() if $self->can('SUPER::init');

    $self->{+TESTS_SEEN}   //= 0;
    $self->{+ASSERTS_SEEN} //= 0;
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

sub ipc {
    my $self = shift;
    return $self->{+IPC} //= Test2::Harness::IPC->new;
}

sub monitor_preloads { 0 }

sub run {
    my $self = shift;

    my $settings = $self->settings;

    if ($self->start()) {
        $self->render();
        $self->stop();

        my $final_data = $self->{+FINAL_DATA} or die "Final data never received from auditor!\n";
        $self->render_final_data($final_data);
        my $pass = $self->{+TESTS_SEEN} && $final_data->{pass};
        $self->render_summary($pass);
        return $pass ? 0 : 1;
    }

    $self->stop();
    return 1;
}

sub start {
    my $self = shift;

    $self->ipc->start();
    $self->parse_args;
    $self->write_settings_to($self->workdir, 'settings.json');

    my $pop = $self->populate_queue();
    $self->terminate_queue();

    return unless $pop;

    $self->setup_plugins();

    $self->start_runner();
    $self->start_collector();
    $self->start_auditor();

    return 1;
}

sub setup_plugins {
    my $self = shift;
    $_->setup($self->settings) for @{$self->settings->yath->plugins};
}

sub teardown_plugins {
    my $self = shift;
    $_->teardown($self->settings) for @{$self->settings->yath->plugins};
}

sub render {
    my $self = shift;

    my $ipc       = $self->ipc;
    my $settings  = $self->settings;
    my $renderers = $self->renderers;
    my $logger    = $self->logger;
    my $plugins = $self->settings->yath->plugins;

    $plugins = [grep {$_->can('handle_event')} @$plugins];

    # render results from log
    my $reader = $self->renderer_reader();
    $reader->blocking(0);
    my $buffer;
    while (1) {
        my $line = <$reader>;
        unless(defined $line) {
            $ipc->wait() if $ipc;
            sleep 0.02;
            next;
        }

        if ($buffer) {
            $line = $buffer . $line;
            $buffer = undef;
        }

        unless (substr($line, -1, 1) eq "\n") {
            $buffer //= "";
            $buffer .= $line;
            next;
        }

        print $logger $line if $logger;
        my $e = decode_json($line);
        last unless defined $e;

        bless($e, 'Test2::Harness::Event');

        if (my $final = $e->{facet_data}->{harness_final}) {
            $self->{+FINAL_DATA} = $final;
        }
        else {
            $_->render_event($e) for @$renderers;
        }

        $self->{+TESTS_SEEN}++   if $e->{facet_data}->{harness_job_launch};
        $self->{+ASSERTS_SEEN}++ if $e->{facet_data}->{assert};

        $_->handle_event($e, $settings) for @$plugins;

        $ipc->wait() if $ipc;
    }
}

sub stop {
    my $self = shift;

    my $plugins = $self->settings->yath->plugins;
    my $settings  = $self->settings;
    my $renderers = $self->renderers;
    my $logger    = $self->logger;
    close($logger) if $logger;

    $self->teardown_plugins();

    $_->finish($settings) for @$plugins;
    $_->finish() for @$renderers;

    my $ipc = $self->ipc;
    $ipc->wait(all => 1);
    $ipc->stop;

    unless ($settings->display->quiet > 2) {
        printf STDERR "\nNo tests were seen!\n" unless $self->{+TESTS_SEEN};

        printf("\nKeeping work dir: %s\n", $self->workdir) if $settings->debug->keep_dirs;

        print "\nWrote log file: " . $settings->logging->log_file . "\n"
            if $settings->logging->log;
    }
}

sub terminate_queue {
    my $self = shift;

    $self->tasks_queue->end();
    $self->state->end_queue();
}

sub run_args {()}

sub build_run {
    my $self = shift;

    return $self->{+RUN} if $self->{+RUN};

    my $settings = $self->settings;
    my $dir = $self->workdir;

    my $run = $settings->build(run => 'Test2::Harness::Run', $self->run_args);

    mkdir($run->run_dir($dir)) or die "Could not make run dir: $!";

    return $self->{+RUN} = $run;
}

sub state {
    my $self = shift;

    $self->{+STATE} //= Test2::Harness::Runner::State->new(
        workdir   => $self->workdir,
        job_count => $self->job_count,
        no_poll   => 1,
    );
}

sub job_count {
    my $self = shift;

    return $self->settings->runner->job_count;
}

sub run_queue {
    my $self = shift;
    my $dir = $self->workdir;
    return $self->{+RUN_QUEUE} //= Test2::Harness::Util::Queue->new(file => File::Spec->catfile($dir, 'run_queue.jsonl'));
}

sub tasks_queue {
    my $self = shift;

    $self->{+TASKS_QUEUE} //= Test2::Harness::Util::Queue->new(
        file => File::Spec->catfile($self->build_run->run_dir($self->workdir), 'queue.jsonl'),
    );
}

sub populate_queue {
    my $self = shift;

    my $run = $self->build_run();
    my $settings = $self->settings;

    my $state = $self->state;
    my $tasks_queue = $self->tasks_queue;
    my $plugins = $self->settings->yath->plugins;

    $state->queue_run($run->queue_item($plugins));

    my @files = @{$run->find_files($plugins, $self->settings)};

    for my $plugin (@$plugins) {
        next unless $plugin->can('sort_files');
        @files = $plugin->sort_files(@files);
    }

    my $job_count = 0;
    for my $file (@files) {
        my $task = $file->queue_item(++$job_count, $run->run_id);
        $state->queue_task($task);
        $tasks_queue->enqueue($task);
    }

    $state->stop_run($run->run_id);

    return $job_count;
}

sub render_summary {
    my $self = shift;
    my ($pass) = @_;

    return if $self->settings->display->quiet > 1;

    my $runtime = sprintf("%.2fs", time() - $self->settings->yath->start);
    my ($user, $system, $cuser, $csystem) = times();

    my $time = time() - $self->settings->yath->start;
    my @times = times();
    unshift @times => sum @times;
    my $percent = $times[0] / $time * 100;

    my @summary = (
        "     File Count: $self->{+TESTS_SEEN}",
        "Assertion Count: $self->{+ASSERTS_SEEN}",
        sprintf("      Wall Time: %.2f seconds", $time),
        sprintf("       CPU Time: %.2f seconds (usr: %.2fs | sys: %.2fs | cusr: %.2fs | csys: %.2fs)", @times),
        sprintf("      CPU Usage: %i%%", $percent),
    );

    my $res = "    -->  Result: " . ($pass ? 'PASSED' : 'FAILED') . "  <--";
    if ($self->settings->display->color && eval { require Term::ANSIColor; 1 }) {
        my $color = $pass ? Term::ANSIColor::color('bold bright_green') : Term::ANSIColor::color('bold bright_red');
        my $reset = Term::ANSIColor::color('reset');
        $res = "$color$res$reset";
    }
    push @summary => $res;

    my $msg = "Yath Result Summary";
    my $length = max map { length($_) } @summary;
    my $prefix = ($length - length($msg)) / 2;

    print "\n";
    print " " x $prefix;
    print "$msg\n";
    print "-" x $length;
    print "\n";
    print join "\n" => @summary;
    print "\n";
}

sub render_final_data {
    my $self = shift;
    my ($final_data) = @_;

    return if $self->settings->display->quiet > 1;

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

    if (my $rows = $final_data->{halted}) {
        print "\nThe following jobs requested all testing be halted:\n";
        print join "\n" => table(
            header => ['Job ID', 'Test File', "Reason"],
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
        no warnings 'once';
        require IO::Compress::Bzip2;
        $self->{+LOGGER} = IO::Compress::Bzip2->new($file) or die "Could not open log file '$file': $IO::Compress::Bzip2::Bzip2Error";
        return $self->{+LOGGER};
    }
    elsif ($settings->logging->gzip) {
        no warnings 'once';
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

    my $run = $self->build_run();
    my $settings = $self->settings;

    my $ipc = $self->ipc;
    $ipc->spawn(
        stdin       => $self->auditor_reader(),
        stdout      => $self->auditor_writer(),
        no_set_pgrp => 1,
        command     => [
            $^X, cover(), $settings->yath->script,
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

    my $dir        = $self->workdir;
    my $run        = $self->build_run();
    my $settings   = $self->settings;
    my $runner_pid = $self->runner_pid;

    my ($rh, $wh);
    pipe($rh, $wh) or die "Could not create pipe";

    my $ipc = $self->ipc;
    $ipc->spawn(
        stdout      => $self->collector_writer,
        stdin       => $rh,
        no_set_pgrp => 1,
        command     => [
            $^X, cover(), $settings->yath->script,
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

    $args{monitor_preloads} //= $self->monitor_preloads;

    my $settings = $self->settings;
    my $dir = $settings->workspace->workdir;

    my $ipc = $self->ipc;
    my $proc = $ipc->spawn(
        stderr => File::Spec->catfile($dir, 'error.log'),
        stdout => File::Spec->catfile($dir, 'output.log'),
        no_set_pgrp => 1,
        command => [
            $^X, cover(), $settings->yath->script,
            (map { "-D$_" } @{$settings->yath->dev_libs}),
            '--no-scan-plugins', # Do not preload any plugin modules
            runner => $dir,
            %args,
        ],
    );

    $self->{+RUNNER_PID} = $proc->pid;

    return $proc;
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

__END__

=head1 POD IS AUTO-GENERATED

