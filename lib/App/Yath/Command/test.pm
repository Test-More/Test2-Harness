package App::Yath::Command::test;
use strict;
use warnings;

our $VERSION = '2.000000';

use Time::HiRes qw/sleep/;
use Test2::Harness::Util qw/mod2file write_file_atomic/;
use Test2::Harness::Util::JSON qw/encode_json/;

use App::Yath::Command::start;
use App::Yath::Command::run;
use Test2::Harness::Event;

use parent 'App::Yath::Command::start';
use parent 'App::Yath::Command::run';
use Test2::Harness::Util::HashBase qw{
    +renderers
};

use Getopt::Yath;
include_options(
    App::Yath::Command::start->option_modules,
    'App::Yath::Command::run',
);

option_group {group => 'runner', category => "Runner Options"} => sub {
    option preload_threshold => (
        type    => 'Scalar',
        short   => 'W',
        alt     => ['Pt'],
        default => 0,

        description => "Only do preload if at least N tests are going to be run. In some cases a full preload takes longer than simply running the tests, this lets you specify a minimum number of test jobs that will be run for preload to happen. The default is 0, and it means always preload."
    );
};

sub starts_runner            { 1 }
sub starts_persistent_runner { 0 }

sub args_include_tests { 1 }

sub group { ' main' }

sub summary  { "Run tests with a clean temporary runner" }

sub description {
    return <<"    EOT";
This yath command will run all the test files for the current project. If no test files are specified this command will look for the 't', and 't2' directories, as well as the 'test.pl' file.

This command is always recursive when given directories.

This command will add 'lib', 'blib/arch' and 'blib/lib' to the perl path for you by default (after any -I's). You can specify -l if you just want lib, -b if you just want the blib paths. If you specify both -l and -b both will be added in the order you specify (order relative to any -I options will also be preserved.  If you do not specify they will be added in this order: -I's, lib, blib/lib, blib/arch. You can also add --no-lib and --no-blib to avoid both.

Any command line argument that is not an option will be treated as a test file or directory of test files to be run.

If you wish to specify the ARGV for tests you may append them after '::'. This is mainly useful for Test::Class::Moose and similar tools. EVERY test executed will get the same ARGV.
    EOT
}

sub process_collector_name { 'yath' }

sub check_argv { 1 }

sub load_plugins   { 1 }
sub load_resources { 1 }
sub load_renderers { 1 }

sub run {
    my $self = shift;

    my $search = $self->fix_test_args();

    # Get list of tests to run
    my $tests = $self->find_tests(@$search) or return $self->no_tests;

    my $settings = $self->settings;

    if (my $pt = $settings->runner->preload_threshold) {
        my $tc = @$tests;
        if ($tc < $pt) {
            print "\n** Test count '$tc' is below the threshold of '$pt', skipping preload. **\n\n";
            $settings->runner->class('Test2::Harness::Runner');
            $settings->runner->preloads([]);
            $settings->runner->preload_early(undef);
        }
    }

    return $self->App::Yath::Command::start::run();
}

sub become_instance {
    my $self = shift;

    $0 = $self->process_base_name;

    my $collector = $self->collector();
    $collector->setup_child_output();

    my $settings = $self->settings;

    my $run_id = $settings->run->run_id;

    my $tests = $self->find_tests();
    my $jobs = [map { Test2::Harness::Run::Job->new(test_file => $_) } @$tests];

    my $ts = Test2::Harness::TestSettings->new($settings->tests->all, clear => $self->{+OPTION_STATE}->{cleared}->{tests});

    my $instance = $self->instance;

    $self->scheduler->set_single_run(1);

    my $run = Test2::Harness::Run->new(
        $settings->run->all,
        aggregator_use_io => 1,
        instance_ipc      => $instance->ipc->[0]->callback,
        test_settings     => $ts,
        jobs              => $jobs,
    );

    $instance->scheduler->queue_run($run);

    $instance->run();

    return 0;
}

sub renderers {
    my $self = shift;
    return $self->{+RENDERERS} //= App::Yath::Options::Renderer->init_renderers($self->settings);
}

sub become_collector {
    my $self = shift;
    my ($pid) = @_;

    $self->start_plugins_and_renderers();

    my $exit = $self->SUPER::become_collector($pid);

    return $self->stop_plugins_and_renderers($exit);
}

sub collector {
    my $self = shift;

    return $self->{+COLLECTOR} if $self->{+COLLECTOR};

    my $settings  = $self->settings;
    my $auditor   = $self->auditor;
    my $plugins   = $self->plugins;
    my $renderers = $self->renderers;
    my $run_id    = $settings->run->run_id;
    my $parser    = Test2::Harness::Collector::IOParser->new(job_id => 0, job_try => 0, run_id => $run_id, type => 'runner');

    my $annotate_plugins = [grep { $_->can('annotate_event') } @$plugins];

    return $self->{+COLLECTOR} = Test2::Harness::Collector->new(
        auditor      => $auditor,
        parser       => $parser,
        job_id       => 0,
        job_try      => 0,
        run_id       => $run_id,
        always_flush => 1,
        output       => sub { $self->handle_event($_) for @_ },

        tick => sub {
            $_->step() for @$renderers;
            $_->tick(type => 'client') for @$plugins;
        },
    );
}

sub handle_event {
    my $self = shift;
    my ($event) = @_;

    bless($event, 'Test2::Harness::Event');

    $self->annotate($event);
    $_->render_event($event) for @{$self->renderers // []};

    return ($event);
}

1;

__END__

    die "Qeueue run";
    die "Fix guard";
    my $guard = Scope::Guard->new(sub { $client->send_and_get(abort => $run_id) });

    die "fix the signal handler to not use the client";
    for my $sig (qw/INT TERM HUP/) {
        $SIG{$sig} = sub {
            $SIG{$sig} = 'DEFAULT';
            print STDERR "\nCought SIG$sig, shutting down...\n";
            $client->send_and_get(abort => $run_id);
            $guard->dismiss();
            kill($sig, $$);
        };
    }



    $guard->dismiss();

    return 0;



