package App::Yath::Command::run;
use strict;
use warnings;

our $VERSION = '2.000000';

use List::Util qw/first/;
use Time::HiRes qw/sleep time/;

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
    +find_tests
    +auditor
    +renderers
    +annotate_plugins
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

    $self->start_plugins_and_renderers();

    # Get list of tests to run
    my $search = $self->fix_test_args();
    my $tests  = $self->find_tests(@$search) || return $self->no_tests;

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

    my $plugins   = $self->plugins   // [];
    my $renderers = $self->renderers // [];

    my @sig_render = grep { $_->can('signal') } @$renderers;
    for my $sig (qw/INT TERM HUP/) {
        $SIG{$sig} = sub {
            $SIG{$sig} = 'DEFAULT';
            eval { $_->($sig) } for @sig_render;
            print STDERR "\nCought SIG$sig, shutting down...\n";
            $client->send_and_get(abort => $run_id);
            $guard->dismiss();
            kill($sig, $$);
        };
    }

    die "API Failure: " . encode_pretty_json($res->{api})
        unless $res->{api}->{success};

    my $lf = Test2::Harness::Util::LogFile->new(client => $client);

    my $run_complete;
    while (!$run_complete) {
        $_->step() for @$renderers;
        $_->tick(type => 'client') for @$plugins;

        $run_complete //= 1 unless $client->active;

        $self->handle_event($_) for $lf->poll;

        while (my $msg = $client->get_message(blocking => !$run_complete, timeout => 0.2)) {
            if ($msg->terminate || $msg->run_complete) {
                $run_complete //= 1;
                $client->refuse_new_connections();
            }

            my $event = $msg->event or next;
            $self->handle_event($event);
        }
    }

    my $exit = $self->stop_plugins_and_renderers();

    $guard->dismiss();

    return $exit;
}

sub renderers {
    my $self = shift;
    $self->{+RENDERERS} //= App::Yath::Options::Renderer->init_renderers($self->settings);
}

sub annotate_plugins {
    my $self = shift;
    return $self->{+ANNOTATE_PLUGINS} //= [grep { $_->can('annotate_event') } @{$self->plugins // []}];
}

sub start_plugins_and_renderers {
    my $self = shift;

    my $settings  = $self->settings;
    my $renderers = $self->renderers;
    my $plugins   = $self->plugins;

    $_->client_setup(settings => $settings) for @$plugins;
    $_->start() for @$renderers;
}

sub handle_event {
    my $self = shift;
    my ($event) = @_;

    my $renderers = $self->renderers;

    $self->annotate($event);

    my @events = $self->auditor->audit($event);
    for my $e (@events) {
        $_->render_event($e) for @$renderers;
    }

    return @events;
}

sub stop_plugins_and_renderers {
    my $self = shift;
    my ($alt_exit) = $@;
    $alt_exit ||= 0;

    my $settings  = $self->settings;
    my $auditor   = $self->auditor;
    my $plugins   = $self->plugins;
    my $renderers = $self->renderers;

    for my $plugin (reverse @$plugins) {
        my @events = $plugin->client_teardown(settings => $settings, auditor => $auditor);
        $self->handle_event($_) for @events;
    }

    $self->handle_event(Test2::Harness::Event->new(
        run_id     => $settings->run->run_id,
        job_id     => 0,
        job_try    => 0,
        event_id   => gen_uuid(),
        stamp      => time,
        facet_data => {harness_final => $auditor->final_data},
    ));

    $_->finish($auditor) for reverse @$renderers;

    my $exit ||= $auditor->exit_value;
    $_->client_finalize(settings => $settings, auditor => $auditor, exit => \$exit) for @$plugins;

    return $exit || $alt_exit;
}

sub annotate {
    my $self = shift;
    my ($event) = @_;

    my $plugins = $self->annotate_plugins or return;
    return unless @$plugins;

    my $settings = $self->{+SETTINGS};

    my $fd = $event->{facet_data};
    for my $p (@$plugins) {
        my %inject = $p->annotate_event($event, $settings);
        next unless keys %inject;

        # Can add new facets, but not modify existing ones.
        # Someone could force the issue by modifying the event directly
        # inside 'annotate_event', this is not supported, but also not
        # forbidden, user beware.
        for my $f (keys %inject) {
            if (exists $fd->{$f}) {
                if ('ARRAY' eq ref($fd->{$f})) {
                    push @{$fd->{$f}} => @{$inject{$f}};
                }
                else {
                    warn "Plugin '$p' tried to add facet '$f' via 'annotate_event()', but it is already present and not a list, ignoring plugin annotation.\n";
                }
            }
            else {
                $fd->{$f} = $inject{$f};
            }
        }
    }
}

sub auditor {
    my $self = shift;

    my $settings = $self->settings;
    my $run = $settings->run;
    my $class = $run->run_auditor;
    require(mod2file($class));

    return $self->{+AUDITOR} //= $class->new();
}

sub no_tests {
    my $self = shift;
    print "Nothing to do, no tests to run!\n";
    return 0;
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
