package App::Yath::Command::test;
use strict;
use warnings;

our $VERSION = '1.000043';

use App::Yath::Options;

use Test2::Harness::Run;
use Test2::Harness::Event;
use Test2::Harness::Util::Queue;
use Test2::Harness::Util::File::JSON;
use Test2::Harness::IPC;

use Test2::Harness::Runner::State;
use Test2::Harness::Util::Queue;

use Test2::Harness::Util::UUID qw/gen_uuid/;
use Test2::Harness::Util::JSON qw/encode_json decode_json JSON/;
use Test2::Harness::Util qw/mod2file open_file chmod_tmp/;
use Test2::Util::Table qw/table/;

use Test2::Harness::Util::Term qw/USE_ANSI_COLOR/;

use File::Spec;
use Fcntl();

use Time::HiRes qw/sleep time/;
use List::Util qw/sum max min/;
use File::Path qw/remove_tree/;
use Carp qw/croak/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw/
    <runner_pid +ipc +signal

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

    <sources

    <final_data

    <coverage_aggregator

    +jobs_file +jobs_queue +jobs_queue_done

    +ptp_collector
    +ptp_events
/;

include_options(
    'App::Yath::Options::Debug',
    'App::Yath::Options::Display',
    'App::Yath::Options::Finder',
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
look for the 't', and 't2' directories, as well as the 'test.pl' file.

This command is always recursive when given directories.

This command will add 'lib', 'blib/arch' and 'blib/lib' to the perl path for
you by default (after any -I's). You can specify -l if you just want lib, -b if
you just want the blib paths. If you specify both -l and -b both will be added
in the order you specify (order relative to any -I options will also be
preserved.  If you do not specify they will be added in this order: -I's, lib,
blib/lib, blib/arch. You can also add --no-lib and --no-blib to avoid both.

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

sub _resize_pipe {
    return unless defined &Fcntl::F_SETPIPE_SZ;
    my ($fh) = @_;

    # 1mb if we can
    my $size = 1024 * 1024 * 1;

    # On linux systems lets go for the smaller of the two between 1mb and
    # system max.
    if (-e '/proc/sys/fs/pipe-max-size') {
        open(my $max, '<', '/proc/sys/fs/pipe-max-size');
        chomp(my $val = <$max>);
        close($max);
        $size = min($size, $val);
    }

    fcntl($fh, Fcntl::F_SETPIPE_SZ(), $size);
}

sub auditor_reader {
    my $self = shift;
    return $self->{+AUDITOR_READER} if $self->{+AUDITOR_READER};
    pipe($self->{+AUDITOR_READER}, $self->{+COLLECTOR_WRITER}) or die "Could not create pipe: $!";
    _resize_pipe($self->{+COLLECTOR_WRITER});
    return $self->{+AUDITOR_READER};
}

sub collector_writer {
    my $self = shift;
    return $self->{+COLLECTOR_WRITER} if $self->{+COLLECTOR_WRITER};
    pipe($self->{+AUDITOR_READER}, $self->{+COLLECTOR_WRITER}) or die "Could not create pipe: $!";
    _resize_pipe($self->{+COLLECTOR_WRITER});
    return $self->{+COLLECTOR_WRITER};
}

sub renderer_reader {
    my $self = shift;
    return $self->{+RENDERER_READER} if $self->{+RENDERER_READER};
    pipe($self->{+RENDERER_READER}, $self->{+AUDITOR_WRITER}) or die "Could not create pipe: $!";
    _resize_pipe($self->{+AUDITOR_WRITER});
    return $self->{+RENDERER_READER};
}

sub auditor_writer {
    my $self = shift;
    return $self->{+AUDITOR_WRITER} if $self->{+AUDITOR_WRITER};
    pipe($self->{+RENDERER_READER}, $self->{+AUDITOR_WRITER}) or die "Could not create pipe: $!";
    _resize_pipe($self->{+AUDITOR_WRITER});
    return $self->{+AUDITOR_WRITER};
}

sub workdir {
    my $self = shift;
    $self->settings->workspace->workdir;
}

sub ipc {
    my $self = shift;
    return $self->{+IPC} //= Test2::Harness::IPC->new(
        handlers => {
            INT  => sub { $self->handle_sig(@_) },
            TERM => sub { $self->handle_sig(@_) },
        }
    );
}

sub handle_sig {
    my $self = shift;
    my ($sig) = @_;

    print STDERR "\nCaught SIG$sig, forwarding signal to child processes...\n";
    $self->ipc->killall($sig);

    if ($self->{+SIGNAL}) {
        print STDERR "\nSecond signal ($self->{+SIGNAL} followed by $sig), exiting now without waiting\n";
        exit 1;
    }

    $self->{+SIGNAL} = $sig;
}

sub monitor_preloads { 0 }

sub run {
    my $self = shift;

    my $settings = $self->settings;
    my $plugins = $self->settings->harness->plugins;

    if ($self->start()) {
        $self->render();
        $self->stop();

        my $final_data = $self->{+FINAL_DATA} or die "Final data never received from auditor!\n";
        my $pass = $self->{+TESTS_SEEN} && $final_data->{pass};
        $self->render_final_data($final_data);
        $self->produce_summary($pass);

        if (@$plugins) {
            my %args = (
                settings     => $settings,
                final_data   => $final_data,
                pass         => $pass ? 1 : 0,
                tests_seen   => $self->{+TESTS_SEEN} // 0,
                asserts_seen => $self->{+ASSERTS_SEEN} // 0,
            );
            $_->finish(%args) for @$plugins;
        }

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

    $self->start_runner(jobs_todo => $pop);

    unless ($self->settings->run->per_test_processors) {
        $self->start_collector();
        $self->start_auditor();
    }

    return 1;
}

sub setup_plugins {
    my $self = shift;
    $_->setup($self->settings) for @{$self->settings->harness->plugins};
}

sub teardown_plugins {
    my $self = shift;
    $_->teardown($self->settings) for @{$self->settings->harness->plugins};
}

sub jobs_queue {
    my $self = shift;

    return $self->{+JOBS_QUEUE} if $self->{+JOBS_QUEUE};

    my $run_dir = File::Spec->catdir($self->workdir, $self->build_run->run_id);
    my $jobs_file = $self->{+JOBS_FILE} //= File::Spec->catfile($run_dir, 'jobs.jsonl');

    return unless -f $jobs_file;

    return $self->{+JOBS_QUEUE} = Test2::Harness::Util::Queue->new(file => $jobs_file);
}

sub ptp_iteration {
    my $self = shift;

    $self->{+PTP_COLLECTOR} //= do {
        $self->{+SOURCES}->{main} = [undef, undef, undef, $self->{+PTP_EVENTS} //= []];

        require Test2::Harness::Collector;
        Test2::Harness::Collector->new(
            settings   => $self->settings,
            workdir    => $self->workdir,
            run_id     => $self->build_run->run_id,
            runner_pid => $self->runner_pid,
            run        => $self->build_run,

            show_runner_output => 1,

            action => sub { push @{$self->{+PTP_EVENTS}} => @_ },
        );
    };

    $self->{+PTP_COLLECTOR}->process_runner_output();

    # Return 1 if the file is not ready yet.
    my $queue = $self->jobs_queue or return 1;

    return 0 if $self->{+JOBS_QUEUE_DONE};

    for my $item ($queue->poll) {
        my ($spos, $epos, $job) = @$item;

        unless ($job) {
            $self->{+JOBS_QUEUE_DONE} = 1;
            last;
        }

        $self->start_processor($job);
    }

    return 1;
}

sub render {
    my $self = shift;

    my $run       = $self->build_run;
    my $ipc       = $self->ipc;
    my $settings  = $self->settings;
    my $renderers = $self->renderers;
    my $logger    = $self->logger;
    my $plugins = $self->settings->harness->plugins;

    my $cover = $settings->logging->write_coverage;
    if ($cover) {
        require Test2::Harness::Log::CoverageAggregator;
        $self->{+COVERAGE_AGGREGATOR} //= Test2::Harness::Log::CoverageAggregator->new();
    }

    $plugins = [grep {$_->can('handle_event')} @$plugins];

    my $ptp = $self->settings->run->per_test_processors;

    my $sources = $self->{+SOURCES} //= {};

    unless ($ptp) {
        # render results from log
        my $reader = $self->renderer_reader();
        $reader->blocking(0);
        my $buffer;
        $sources->{main} = [$reader, \$buffer];
    }

    while (1) {
        last if $self->{+SIGNAL};
        $ipc->wait() if $ipc;

        my $done = 0;
        my $keys = 0;
        if ($ptp) {
            $done = !$self->ptp_iteration;
            $keys = keys %$sources;
            last if $done && !$keys;
        }
        elsif (!keys %$sources) {
            last;
        }

        my $count = 0;
        my %seen;
        # Make sure main comes first, and earlier attempts before later
        for my $key (sort { $a eq 'main' ? -1 : $b eq 'main' ? 1 : $sources->{$a}->[0]->{stamp} <=> $sources->{$b}->[0]->{stamp} || $a cmp $b } keys %$sources) {
            # This is to make sure no events from a retry come before we finish processing the original.
            next if $key =~ m/^(.+)\+\d+$/ && $seen{$1}++;

            my $data = $sources->{$key};
            my ($job, $reader, $buffer, $events) = @$data;

            while (1) {
                my $e;
                if ($events) {
                    unless (@$events) {
                        last unless $done && $keys == 1;
                        $e = undef;
                    }

                    $e = shift @$events;
                    print $logger encode_json($e) . "\n" if $logger && defined $e;
                }
                else {
                    my $line = <$reader> // last;
                    $count++;

                    if ($$buffer) {
                        $line = $buffer . $line;
                        $$buffer = undef;
                    }

                    unless (substr($line, -1, 1) eq "\n") {
                        $$buffer //= "";
                        $$buffer .= $line;
                        last;
                    }

                    $e = decode_json($line);
                    print $logger $line if $logger && defined $e;
                }

                unless(defined $e) {
                    delete $sources->{$key};
                    last;
                }

                bless($e, 'Test2::Harness::Event');

                $self->{+TESTS_SEEN}++   if $e->{facet_data}->{harness_job_launch};
                $self->{+ASSERTS_SEEN}++ if $e->{facet_data}->{assert};

                if (my $final = $e->{facet_data}->{harness_final}) {
                    $self->add_final_data($final);
                    last;
                }

                $_->render_event($e) for @$renderers;

                $self->{+COVERAGE_AGGREGATOR}->process_event($e) if $cover && (
                    $e->{facet_data}->{coverage} ||
                    $e->{facet_data}->{harness_job_end} ||
                    $e->{facet_data}->{harness_job_start}
                );

                $_->handle_event($e, $settings) for @$plugins;
            }
        }

        sleep 0.2 unless $count;
    }

    if ($ptp) {
        if (my $final = $self->{+FINAL_DATA}) {
            my %seen;
            $final->{failed} = [grep { !$seen{$_->[0]}++ } @{$final->{failed}}] if $final->{failed};

            %seen = ();
            $final->{halted} = [grep { !$seen{$_->[0]}++ } @{$final->{halted}}] if $final->{halted};

            %seen = ();
            $final->{unseen} = [grep { !$seen{$_->[0]}++ } @{$final->{unseen}}] if $final->{unseen};

            %seen = ();
            $final->{retried} = [reverse grep { !$seen{$_->[0]}++ } reverse @{$final->{retried}}] if $final->{retried};

            my $e = Test2::Harness::Event->new(
                job_id     => 0,
                stamp      => time,
                event_id   => gen_uuid(),
                run_id     => $run->run_id,
                facet_data => {harness_final => $final},
            );

            print $logger encode_json($e) . "\n" if $logger;
            $_->render_event($e) for @$renderers;
            $_->handle_event($e, $settings) for @$plugins;
        }

        remove_tree($self->build_run->run_dir($self->workdir), {safe => 1, keep_root => 0})
            unless $self->settings->debug->keep_dirs;
    }

    print $logger "null\n" if $logger;
    return;
}

sub add_final_data {
    my $self = shift;
    my ($new) = @_;

    my $data = $self->{+FINAL_DATA} //= {pass => 1};

    $data->{pass} &&= $new->{pass};
    push @{$data->{failed}}  => @{$new->{failed}}  if $new->{failed};
    push @{$data->{retried}} => @{$new->{retried}} if $new->{retried};
    push @{$data->{halted}}  => @{$new->{halted}}  if $new->{halted};
    push @{$data->{unseen}}  => @{$new->{unseen}}  if $new->{unseen};

    return $data;
}

sub stop {
    my $self = shift;

    my $settings  = $self->settings;
    my $renderers = $self->renderers;
    my $logger    = $self->logger;
    close($logger) if $logger;

    $self->teardown_plugins();

    $_->finish() for @$renderers;

    my $ipc = $self->ipc;
    print STDERR "Waiting for child processes to exit...\n" if $self->{+SIGNAL};
    $ipc->wait(all => 1);
    $ipc->stop;

    my $cover = $settings->logging->write_coverage;
    if ($cover) {
        my $coverage = $self->{+COVERAGE_AGGREGATOR}->coverage;

        if (open(my $fh, '>', $cover)) {
            print $fh encode_json($coverage);
            close($fh);
        }
        else {
            warn "Could not write coverage file '$cover': $!";
        }
    }

    unless ($settings->display->quiet > 2) {
        printf STDERR "\nNo tests were seen!\n" unless $self->{+TESTS_SEEN};

        printf("\nKeeping work dir: %s\n", $self->workdir)
            if $settings->debug->keep_dirs;

        print "\nWrote log file: " . $settings->logging->log_file . "\n"
            if $settings->logging->log;

        print "\nWrote coverage file: $cover\n"
            if $cover;
    }
}

sub terminate_queue {
    my $self = shift;

    $self->tasks_queue->end();
    $self->state->end_queue();
}

sub build_run {
    my $self = shift;

    return $self->{+RUN} if $self->{+RUN};

    my $settings = $self->settings;
    my $dir = $self->workdir;

    my $run = $settings->build(run => 'Test2::Harness::Run');

    mkdir($run->run_dir($dir)) or die "Could not make run dir: $!";
    chmod_tmp($dir);

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

sub finder_args {()}

sub populate_queue {
    my $self = shift;

    my $run = $self->build_run();
    my $settings = $self->settings;
    my $finder = $settings->build(finder => $settings->finder->finder, $self->finder_args);

    my $state = $self->state;
    my $tasks_queue = $self->tasks_queue;
    my $plugins = $settings->harness->plugins;

    $state->queue_run($run->queue_item($plugins));

    my @files = @{$finder->find_files($plugins, $self->settings)};

    for my $plugin (@$plugins) {
        next unless $plugin->can('sort_files');
        @files = $plugin->sort_files(@files);
    }

    my $job_count = 0;
    for my $file (@files) {
        my $task = $file->queue_item(++$job_count, $run->run_id,
            $settings->check_prefix('display') ? (verbose => $settings->display->verbose) : (),
        );
        $state->queue_task($task);
        $tasks_queue->enqueue($task);
    }

    $state->stop_run($run->run_id);

    return $job_count;
}

sub produce_summary {
    my $self = shift;
    my ($pass) = @_;

    my $settings = $self->settings;

    my $time_data = {
        start => $settings->harness->start,
        stop  => time(),
    };

    $time_data->{wall} = $time_data->{stop} - $time_data->{start};

    my @times = times();
    @{$time_data}{qw/user system cuser csystem/} = @times;
    $time_data->{cpu} = sum @times;

    my $cpu_usage = int($time_data->{cpu} / $time_data->{wall} * 100);

    $self->write_summary($pass, $time_data, $cpu_usage);
    $self->render_summary($pass, $time_data, $cpu_usage);
}

sub write_summary {
    my $self = shift;
    my ($pass, $time_data, $cpu_usage) = @_;

    my $file = $self->settings->debug->summary or return;

    my $final_data = $self->{+FINAL_DATA};

    my $failures = @{$final_data->{failed} // []};

    my %data = (
        %$final_data,

        pass => $pass ? JSON->true : JSON->false,

        total_failures => $failures              // 0,
        total_tests    => $self->{+TESTS_SEEN}   // 0,
        total_asserts  => $self->{+ASSERTS_SEEN} // 0,

        cpu_usage => $cpu_usage,

        times => $time_data,
    );

    require Test2::Harness::Util::File::JSON;
    my $jfile = Test2::Harness::Util::File::JSON->new(name => $file);
    $jfile->write(\%data);

    print "\nWrote summary file: $file\n\n";

    return;
}

sub render_summary {
    my $self = shift;
    my ($pass, $time_data, $cpu_usage) = @_;

    return if $self->settings->display->quiet > 1;

    my $final_data = $self->{+FINAL_DATA};
    my $failures = @{$final_data->{failed} // []};

    my @summary = (
        $failures ? ("     Fail Count: $failures") : (),
        "     File Count: $self->{+TESTS_SEEN}",
        "Assertion Count: $self->{+ASSERTS_SEEN}",
        $time_data ? (
            sprintf("      Wall Time: %.2f seconds", $time_data->{wall}),
            sprintf("       CPU Time: %.2f seconds (usr: %.2fs | sys: %.2fs | cusr: %.2fs | csys: %.2fs)", @{$time_data}{qw/cpu user system cuser csystem/}),
            sprintf("      CPU Usage: %i%%", $cpu_usage),
        ) : (),
    );

    my $res = "    -->  Result: " . ($pass ? 'PASSED' : 'FAILED') . "  <--";
    if ($self->settings->display->color && USE_ANSI_COLOR) {
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
            header => ['Job ID', 'Times Run', 'Test File', "Succeeded Eventually?"],
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

sub start_processor {
    my $self = shift;
    my ($job) = @_;

    my $dir        = $self->workdir;
    my $ipc        = $self->ipc;
    my $run        = $self->build_run();
    my $runner_pid = $self->runner_pid;
    my $settings   = $self->settings;

    my ($from_processor, $to_renderer);
    pipe($from_processor, $to_renderer) or die "Could not open pipe: $!";
    _resize_pipe($to_renderer);

    my ($from_renderer, $to_processor);
    pipe($from_renderer, $to_processor) or die "Could not open pipe: $!";
    _resize_pipe($to_processor);

    $ipc->spawn(
        stdout      => $to_renderer,
        stdin       => $from_renderer,
        no_set_pgrp => 1,
        command     => [
            $^X, cover(), $settings->harness->script,
            (map { "-D$_" } @{$settings->harness->dev_libs}),
            '--no-scan-plugins',    # Do not preload any plugin modules
            processor => 'Test2::Harness::Processor',
            $dir, $run->run_id, $runner_pid,
            show_runner_output => 1,
        ],
    );

    close($to_renderer);
    close($from_renderer);
    print $to_processor encode_json($run) . "\n";
    print $to_processor encode_json($job) . "\n";
    close($to_processor);

    my $job_id = $job->{job_id} or die "No job id!";
    my $job_try = $job_id . '+' . $job->{is_try};

    $from_processor->blocking(0);
    my $buffer;
    $self->{+SOURCES}->{$job_try} = [$job, $from_processor, \$buffer];
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
            $^X, cover(), $settings->harness->script,
            (map { "-D$_" } @{$settings->harness->dev_libs}),
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
            $^X, cover(), $settings->harness->script,
            (map { "-D$_" } @{$settings->harness->dev_libs}),
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

    my @prof;
    if ($settings->runner->nytprof) {
        push @prof => '-d:NYTProf';
    }

    my $ipc = $self->ipc;
    my $proc = $ipc->spawn(
        stderr => File::Spec->catfile($dir, 'error.log'),
        stdout => File::Spec->catfile($dir, 'output.log'),
        env_vars => { @prof ? (NYTPROF => 'start=no:addpid=1') : () },
        no_set_pgrp => 1,
        command => [
            $^X, @prof, cover(), $settings->harness->script,
            (map { "-D$_" } @{$settings->harness->dev_libs}),
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

    my $dest = $settings->finder->search;
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

