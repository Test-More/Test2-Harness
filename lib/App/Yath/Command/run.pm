package App::Yath::Command::run;
use strict;
use warnings;

our $VERSION = '2.000000';

use List::Util qw/first/;
use Time::HiRes qw/sleep/;

use Scope::Guard;

use App::Yath::Client;

use Test2::Harness::Event;
use Test2::Harness::Run;
use Test2::Harness::Run::Job;
use Test2::Harness::Collector::Auditor::Run;
use Test2::Harness::Util::LogFile;

use Test2::Harness::Util qw/mod2file write_file_atomic/;
use Test2::Harness::Util::JSON qw/encode_json encode_pretty_json/;
use Test2::Harness::Util::UUID qw/gen_uuid/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw{
    +plugins
    +find_tests
};

use Getopt::Yath;
include_options(
    'App::Yath::Options::IPC',
    'App::Yath::Options::Finder',
    'App::Yath::Options::Renderer',
    'App::Yath::Options::Run',
    'App::Yath::Options::Tests',
    'App::Yath::Options::Yath',
);

sub args_include_tests { 1 }

sub group { 'daemon' }

sub summary { "Run tests" }

warn "FIXME";

sub description {
    return <<"    EOT";
    FIXME
    EOT
}

sub run {
    my $self = shift;

    warn "Fix this";
    $0 = "yath run";

    my $settings = $self->settings;

    my $search = $self->fix_test_args();

    # Get list of tests to run
    my $tests = $self->find_tests(@$search) || return $self->no_tests;

    my $renderers = App::Yath::Options::Renderer->init_renderers($settings);

    my $client = App::Yath::Client->new(settings => $settings);

    my $run_id = $settings->run->run_id;

    my $jobs = [map { Test2::Harness::Run::Job->new(test_file => $_) } @$tests];

    my $ts = Test2::Harness::TestSettings->new($settings->tests->all, clear => $self->{+OPTION_STATE}->{cleared}->{tests});

    my $run = Test2::Harness::Run->new(
        $settings->run->all,
        aggregator_ipc => $client->connect->callback,
        test_settings  => $ts,
        jobs           => $jobs,
    );

    my $res = $client->queue_run($run);

    my $guard = Scope::Guard->new(sub { $client->send_and_get(abort => $run_id) });

    for my $sig (qw/INT TERM HUP/) {
        $SIG{$sig} = sub {
            $SIG{$sig} = 'DEFAULT';
            print STDERR "\nCought SIG$sig, shutting down...\n";
            $client->send_and_get(abort => $run_id);
            $guard->dismiss();
            kill($sig, $$);
        };
    }

    die "API Failure: " . encode_pretty_json($res->{api})
        unless $res->{api}->{success};

    my $lf = Test2::Harness::Util::LogFile->new(client => $client);

    my $auditor = Test2::Harness::Collector::Auditor::Run->new();
    my $run_complete;
    while (!$run_complete) {
        $run_complete //= 1 unless $client->active;

        for my $event ($lf->poll) {
            $auditor->audit($event);
            $_->render_event($event) for @$renderers;
        }

        while (my $msg = $client->get_message(blocking => !$run_complete, timeout => 0.2)) {
            if ($msg->terminate || $msg->run_complete) {
                $run_complete //= 1;
                $client->refuse_new_connections();
            }

            my $event = $msg->event or next;

            $auditor->audit($event);
            $_->render_event($event) for @$renderers;
        }
    }

    $guard->dismiss();

    for my $r (@$renderers) {
        $r->finish($auditor);
    }

    return $auditor->exit_value;
}

sub no_tests {
    my $self = shift;
    print "Nothing to do, no tests to run!\n";
    return 0;
}

sub plugins {
    my $self = shift;

    warn "init plugins plz...";

    return $self->{+PLUGINS} //= [];
}

sub fix_test_args {
    my $self = shift;

    my $settings = $self->settings;

    my (@tests, @test_args);
    my $list = \@tests;
    for my $arg (@{$self->{+ARGS} // []}) {
        if ($arg eq '::') {
            $list = \@test_args;
            next;
        }

        push @$list => $arg;
    }

    $settings->tests->option(args => \@test_args) if @test_args;

    return \@tests;
}

sub find_tests {
    my $self  = shift;
    my @tests = @_;

    return $self->{+FIND_TESTS} if $self->{+FIND_TESTS};

    my $settings     = $self->settings;
    my $finder_class = $settings->finder->class;

    require(mod2file($finder_class));

    my $finder = $finder_class->new($settings->finder->all, settings => $settings, search => \@tests);
    my $tests = $finder->find_files($self->plugins);

    return unless $tests && @$tests;
    return $self->{+FIND_TESTS} = $tests;
}

1;
