package App::Yath::Command::start;
use strict;
use warnings;

our $VERSION = '2.000000';

use POSIX();

use Test2::Harness::Instance;
use Test2::Harness::TestSettings;
use Test2::Harness::IPC::Protocol;
use Test2::Harness::Collector;
use Test2::Harness::Collector::IOParser;
use App::Yath::Renderer::Default;

use Test2::Harness::Util qw/mod2file/;
use Test2::Harness::IPC::Util qw/pid_is_running/;
use Test2::Harness::Util::JSON qw/encode_json/;

use File::Path qw/remove_tree/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw{
    +log_file
};

use Getopt::Yath;
include_options(
    'App::Yath::Options::IPC',
    'App::Yath::Options::Harness',
    'App::Yath::Options::Resource',
    'App::Yath::Options::Runner',
    'App::Yath::Options::Scheduler',
    'App::Yath::Options::Yath',
    'App::Yath::Options::Renderer',
    'App::Yath::Options::Tests',
);

option_group {group => 'start', category => "Start Options"} => sub {
    option daemon => (
        type => 'Bool',
        description => "Daemonize and return to console",
        default     => 1,
    );
};

sub starts_runner            { 1 }
sub starts_persistent_runner { 1 }

sub args_include_tests { 0 }

sub group { 'daemon' }

sub summary  { "Start a test runner" }

warn "FIXME";
sub description {
    return <<"    EOT";
    FIXME
    EOT
}

sub run {
    my $self = shift;

    $0 = "yath-daemon-launcher";

    my $settings = $self->settings;

    if ($settings->start->daemon) {
        close(STDIN);
        open(STDIN, '<', "/dev/null") or die "Could not open devnull: $!";
        POSIX::setsid();
        my $pid = fork // die "Could not fork";
        if ($pid) {
            sleep 2;
            kill('HUP', $pid);
            exit(0);
        }
    }

    my $collector = $self->init_collector();

    my $pid = fork // die "Could not fork: $!";
    if ($pid) {
        $0 = "yath-daemon-collector";

        my $exit = $collector->process($pid);

        remove_tree($settings->harness->workdir, {safe => 1, keep_root => 0})
            unless $settings->harness->keep_dirs;

        return $exit;
    }
    else {
        $0 = "yath-daemon";
        $collector->setup_child_output();
        return $self->start_instance();
    }

    return 0;
}

sub log_file {
    my $self = shift;
    return $self->{+LOG_FILE} //= File::Spec->catfile($self->settings->harness->workdir, 'log.jsonl');
}

sub init_collector {
    my $self = shift;
    my $settings = $self->settings;

    my $out_file = $self->log_file;

    my $verbose = 2;
    $verbose = 0 if $settings->start->daemon;
    $verbose = 0 if $settings->renderer->quiet;
    my $renderers = App::Yath::Options::Renderer->init_renderers($settings, verbose => $verbose, progress => 0);

    $SIG{HUP} = sub { $renderers = undef };

    open(my $log, '>', $out_file) or die "Could not open '$out_file' for writing: $!";
    $log->autoflush(1);

    my $parser    = Test2::Harness::Collector::IOParser->new(job_id => 0, job_try => 0, run_id => 0, type => 'runner');
    my $collector = Test2::Harness::Collector->new(
        parser  => $parser,
        job_id  => 0,
        job_try => 0,
        run_id  => 0,
        output => sub {
            for my $e (@_) {
                print $log encode_json($e), "\n";
                return unless $renderers;
                $_->render_event($e) for @$renderers;
            }
        }
    );
}

sub start_instance {
    my $self = shift;

    my $settings = $self->settings;

    my $ipc = $self->build_ipc();
    my $runner = $self->build_runner();
    my $scheduler = $self->build_scheduler(runner => $runner);

    my $instance = Test2::Harness::Instance->new(
        ipc       => $ipc,
        scheduler => $scheduler,
        runner    => $runner,
        log_file  => $self->log_file,
    );

    $instance->run;

    return 0;
}

sub build_ipc {
    my $self = shift;

    my $ipc_s = App::Yath::Options::IPC->vivify_ipc($self->settings);
    my $ipc = Test2::Harness::IPC::Protocol->new(protocol => $ipc_s->{protocol});
    $ipc->start($ipc_s->{address}, $ipc_s->{port});

    return $ipc;
}

sub build_scheduler {
    my $self = shift;
    my %params = @_;

    my $scheduler_s = $self->settings->scheduler;
    my $class = $scheduler_s->class;
    require(mod2file($class));

    return $class->new($scheduler_s->all, %params);
}

sub build_runner {
    my $self = shift;
    my %params = @_;

    my $settings = $self->settings;
    my $runner_s = $settings->runner;
    my $class = $runner_s->class;
    require(mod2file($class));

    my $ts = Test2::Harness::TestSettings->new($settings->tests->all);

    return $class->new($runner_s->all, test_settings => $ts, workdir => $settings->harness->workdir, %params);
}

1;
