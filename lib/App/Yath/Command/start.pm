package App::Yath::Command::start;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Harness::Instance;
use Test2::Harness::TestSettings;
use Test2::Harness::IPC::Protocol;
use Test2::Harness::Collector;
use Test2::Harness::Collector::IOParser;

use Test2::Harness::Util qw/mod2file/;
use Test2::Harness::IPC::Util qw/pid_is_running/;
use Test2::Harness::Util::JSON qw/encode_json/;

use File::Path qw/remove_tree/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw{
    +log_file

    +ipc
    +runner
    +scheduler
    +resources
    +instance
    +collector
};

sub option_modules {
    return (
        'App::Yath::Options::IPC',
        'App::Yath::Options::Harness',
        'App::Yath::Options::Resource',
        'App::Yath::Options::Runner',
        'App::Yath::Options::Scheduler',
        'App::Yath::Options::Yath',
        'App::Yath::Options::Renderer',
        'App::Yath::Options::Tests',
    );
}

use Getopt::Yath;
include_options(__PACKAGE__->option_modules);

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

sub process_base_name { shift->should_daemonize ? "yath-daemon" : "yath-instance" }
sub process_collector_name { shift->process_base_name . "-collector" }

sub run {
    my $self = shift;

    $0 = $self->process_base_name . "-launcher";

    $self->become_daemon if $self->should_daemonize();

    # Need to get this pre-fork
    my $collector = $self->collector();

    my $pid = fork // die "Could not fork: $!";
    return $self->become_collector($pid) if $pid;
    return $self->become_instance();
}

sub should_daemonize {
    my $self = shift;

    my $settings = $self->settings;

    return 0 unless $settings->check_group('start');
    return 1 if $settings->start->daemon;
    return 0;
}

sub become_daemon {
    my $self = shift;

    require POSIX;

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

sub become_instance {
    my $self = shift;

    $0 = $self->process_base_name;
    my $collector = $self->collector();
    $collector->setup_child_output();

    $self->instance->run;

    return 0;
}

sub become_collector {
    my $self = shift;
    my ($pid) = @_;

    my $settings = $self->settings;

    $0 = $self->process_collector_name;

    my $collector = $self->collector();
    my $exit = $collector->process($pid);

    remove_tree($settings->harness->workdir, {safe => 1, keep_root => 0})
        unless $settings->harness->keep_dirs;

    return $exit;
}

sub log_file {
    my $self = shift;
    return $self->{+LOG_FILE} //= File::Spec->catfile($self->settings->harness->workdir, 'log.jsonl');
}

sub collector {
    my $self = shift;

    return $self->{+COLLECTOR} if $self->{+COLLECTOR};

    my $settings = $self->settings;

    my $out_file = $self->log_file;

    my $verbose = 2;
    $verbose = 0 if $settings->start->daemon;
    $verbose = 0 if $settings->renderer->quiet;
    my $renderers = App::Yath::Options::Renderer->init_renderers($settings, verbose => $verbose, progress => 0);

    $SIG{HUP} = sub { $renderers = undef };

    open(my $log, '>', $out_file) or die "Could not open '$out_file' for writing: $!";
    $log->autoflush(1);

    my $parser = Test2::Harness::Collector::IOParser->new(job_id => 0, job_try => 0, run_id => 0, type => 'runner');
    return $self->{+COLLECTOR} = Test2::Harness::Collector->new(
        parser       => $parser,
        job_id       => 0,
        job_try      => 0,
        run_id       => 0,
        always_flush => 1,
        output       => sub {
            for my $e (@_) {
                print $log encode_json($e), "\n";
                return unless $renderers;
                $_->render_event($e) for @$renderers;
            }
        }
    );
}

sub instance {
    my $self = shift;

    return $self->{+INSTANCE} if $self->{+INSTANCE};

    my $settings = $self->settings;

    my $ipc       = $self->ipc();
    my $runner    = $self->runner();
    my $scheduler = $self->scheduler();
    my $resources = $self->resources();
    my $plugins = $self->plugins();

    return $self->{+INSTANCE} = Test2::Harness::Instance->new(
        ipc        => $ipc,
        scheduler  => $scheduler,
        runner     => $runner,
        resources  => $resources,
        plugins    => $plugins,
        log_file   => $self->log_file,
        single_run => 1,
    );
}

sub ipc {
    my $self = shift;

    return $self->{+IPC} if $self->{+IPC};

    my $ipc_s = App::Yath::Options::IPC->vivify_ipc($self->settings);
    my $ipc = Test2::Harness::IPC::Protocol->new(protocol => $ipc_s->{protocol});
    $ipc->start($ipc_s->{address}, $ipc_s->{port});

    return $self->{+IPC} = $ipc;
}

sub scheduler {
    my $self = shift;

    return $self->{+SCHEDULER} if $self->{+SCHEDULER};

    my $runner    = $self->runner;
    my $resources = $self->resources;
    my $plugins   = $self->plugins;

    my $scheduler_s = $self->settings->scheduler;
    my $class       = $scheduler_s->class;
    require(mod2file($class));

    return $self->{+SCHEDULER} = $class->new($scheduler_s->all, runner => $runner, resources => $resources, plugins => $plugins);
}

sub runner {
    my $self = shift;

    return $self->{+RUNNER} if $self->{+RUNNER};

    my $plugins  = $self->plugins;
    my $settings = $self->settings;
    my $runner_s = $settings->runner;
    my $class    = $runner_s->class;
    require(mod2file($class));

    my $ts = Test2::Harness::TestSettings->new($settings->tests->all);

    return $self->{+RUNNER} = $class->new($runner_s->all, test_settings => $ts, workdir => $settings->harness->workdir, plugins => $plugins);
}

sub resources {
    my $self = shift;

    return $self->{+RESOURCES} if $self->{+RESOURCES};

    my $settings = $self->settings;
    my $res_s    = $settings->resource;
    my $res_classes = $res_s->classes;

    my @res_class_list = keys %$res_classes;
    require(mod2file($_)) for @res_class_list;

    @res_class_list = sort { $a->sort_weight <=> $b->sort_weight } @res_class_list;

    my @resources;
    for my $mod (@res_class_list) {
        push @resources => $mod->new($res_s->all, @{$res_classes->{$mod}}, $mod->isa('App::Yath::Resource') ? (settings => $settings) : ());
    }

    return $self->{+RESOURCES} = \@resources;
}

1;
