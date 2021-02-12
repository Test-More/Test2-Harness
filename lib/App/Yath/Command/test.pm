package App::Yath::Command::test;
use strict;
use warnings;

our $VERSION = '1.000043';

use App::Yath::Options;

use Test2::Harness::Run;
use Test2::Harness::Util::Queue;
use Test2::Harness::Util::File::JSON;
use Test2::Harness::IPC;

use Test2::Harness::Runner::State;

use Test2::Harness::Util::JSON qw/encode_json decode_json JSON/;
use Test2::Harness::Util qw/mod2file open_file chmod_tmp/;
use Test2::Util::Table qw/table/;

use Test2::Harness::Util::Term qw/USE_ANSI_COLOR/;

use File::Spec;
use Fcntl();

use Time::HiRes qw/sleep time/;
use List::Util qw/sum max min/;
use Carp qw/croak/;

use Test2::Harness::Event qw{
    EFLAG_TERMINATOR
    EFLAG_SUMMARY
    EFLAG_HARNESS
    EFLAG_ASSERT
    EFLAG_EMINENT
    EFLAG_STATE
    EFLAG_PEEK
    EFLAG_COVERAGE
};

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw/
    <runner_pid +ipc +signal

    +run

    +fifo +fifo_rh

    +renderers
    +logger

    +asserts_seen

    +run_queue
    +tasks_queue
    +state
    +jobs

    <summaries
    +final_data

    <coverage_aggregator
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

    $self->{+ASSERTS_SEEN} //= 0;
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

        my $final_data = $self->final_data;
        my $pass = $final_data->{pass};
        $self->render_final_data($final_data);
        $self->produce_summary($pass);

        if (@$plugins) {
            my %args = (
                settings     => $settings,
                final_data   => $final_data,
                pass         => $pass ? 1 : 0,
                tests_seen   => scalar(@{$self->{+SUMMARIES} // []}),
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

sub render {
    my $self = shift;

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

    my $warned = 0;

    # render results from log
    my $reader = $self->fifo_rh;
    while (1) {
        return if $self->{+SIGNAL};

        my $line = $reader->read_message // last;

        my $flags = substr($line, 0, 1, '');
        print $logger $line, "\n" if $logger;

        # All done
        last if $flags & EFLAG_TERMINATOR && $line =~ m/^null$/i;

        my $e = Test2::Harness::Event->new(json => $line, flags => $flags);

        push @{$self->{+SUMMARIES}->{$e->job_id}} => $e if $flags & EFLAG_SUMMARY;

        $self->{+COVERAGE_AGGREGATOR}->process_event($e) if $cover && $flags & EFLAG_COVERAGE;

        $self->{+ASSERTS_SEEN}++ if $flags & EFLAG_ASSERT;

        $_->render_event($e) for @$renderers;
        $_->handle_event($e, $settings) for @$plugins;

        $ipc->wait() if $ipc;
    }

    my $e = Test2::Harness::Event->new(
        facet_data => {
            harness => {
                job_id        => 0,
                job_try       => 0,
                run_id        => $self->{+RUN}->run_id,
                event_id      => gen_uuid(),
                stamp         => time,
                harness_final => $self->final_data,
                from_stream   => 'harness',
            },
        },
    );

    print $logger encode_json($e), "\n" if $logger;
    $_->render_event($e) for @$renderers;
    $_->handle_event($e, $settings) for @$plugins;
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
        printf STDERR "\nNo tests were completed!\n" unless $self->{+SUMMARIES} && @{$self->{+SUMMARIES}};

        printf("\nKeeping work dir: %s\n", $self->workdir)
            if $settings->debug->keep_dirs;

        print "\nWrote log file: " . $settings->logging->log_file . "\n"
            if $settings->logging->log;

        print "\nWrote coverage file: $cover\n"
            if $cover;
    }
}

sub final_data {
    my $self = shift;

    return $self->{+FINAL_DATA} if $self->{+FINAL_DATA};

    my $final_data = {pass => 1};
    my $summaries  = $self->{+SUMMARIES} //= {};
    my $jobs       = $self->{+JOBS}      //= {};

    my %seen;
    for my $job_id (keys(%$jobs), keys(%$summaries)) {
        next if $seen{$job_id}++;

        my $results = $summaries->{$job_id};
        my $task    = $jobs->{$job_id} // {file => '??? MISSING TASK ???'};

        unless ($results && @$results) {
            $final_data->{pass} = 0;
            push @{$final_data->{unseen}} => [$job_id, $task->{file}];
            next;
        }

        my $f     = $results->[-1]->facet_data;
        my $end   = $f->{harness_job_end};
        my $file  = $end->{rel_file};
        my $fail  = $end->{fail};
        my $halt  = $end->{halt};
        my $count = scalar(@$results);
        my $pass  = $fail ? 'NO' : 'YES';

        $final_data->{pass} = 0 if $fail || $halt;

        if ($results && !$task) {
            $final_data->{pass} = 0;
            push @{$final_data->{extra}} => [$job_id, $file];
            next;
        }

        push @{$final_data->{failed}}  => [$job_id, $file]                if $fail;
        push @{$final_data->{halted}}  => [$job_id, $file, $halt]         if $halt;
        push @{$final_data->{retried}} => [$job_id, $count, $file, $pass] if $count > 1;
    }

    return $self->{+FINAL_DATA} = $final_data;
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
        $self->{+JOBS}->{$task->{job_id}} = $task;
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

    my $final_data = $self->final_data;

    my $failures = @{$final_data->{failed} // []};

    my %data = (
        %$final_data,

        pass => $pass ? JSON->true : JSON->false,

        total_failures => $failures              // 0,
        total_asserts  => $self->{+ASSERTS_SEEN} // 0,
        total_tests    => scalar(@{$self->{+SUMMARIES} //= []}),

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

    my $final_data = $self->final_data;
    my $failures = @{$final_data->{failed} // []};

    my @summary = (
        $failures ? ("     Fail Count: $failures") : (),
        "     File Count: " . scalar(@{$self->{+SUMMARIES} // []}),
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

    if (my $rows = $final_data->{extra}) {
        print "\nThe following extra(?) jobs ran:\n";
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

