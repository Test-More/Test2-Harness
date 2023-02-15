package App::Yath::Plugin::YathUIDB;
use strict;
use warnings;

our $VERSION = '0.000130';

use Test2::Harness::UI::Util qw/config_from_settings/;
use Test2::Harness::Util::JSON qw/decode_json/;
use Test2::Harness::Util qw/mod2file looks_like_uuid/;

use App::Yath::Options;
use parent 'App::Yath::Plugin';

option_group {prefix => 'yathui', category => "YathUI Options"} => sub {
    option user => (
        type => 's',
        description => 'Username to attach to the data sent to the db',
        default => sub { $ENV{USER} },
    );

    option schema => (
        type => 's',
        default => 'PostgreSQL',
        long_examples => [' PostgreSQL', ' MySQL', ' MySQL56'],
        description => "What type of DB/schema to use when using a temporary database",
    );

    option port => (
        type => 's',
        long_examples => [' 8080'],
        description => 'Port to use when running a local server',
        default => 8080,
    );

    option port_command => (
        type => 's',
        long_examples => [' get_port.sh', ' get_port.sh --pid $$'],
        description => 'Use a command to get a port number. "$$" will be replaced with the PID of the yath process',
    );

    option resources => (
        type => 'd',
        description => 'Send resource info (for supported resources) to yathui at the specified interval in seconds (5 if not specified)',
        long_examples => ['', '=5'],
        autofill => 5,
    );

    option only => (
        type => 'b',
        description => 'Only use the YathUI renderer',
    );

    option db => (
        type => 'b',
        description => 'Add the YathUI DB renderer in addition to other renderers',
    );

    option only_db => (
        type => 'b',
        description => 'Only use the YathUI DB renderer',
    );

    option render => (
        type => 'b',
        description => 'Add the YathUI renderer in addition to other renderers',
    );

    post 200 => sub {
        my %params = @_;
        my $settings = $params{settings};

        my $yathui = $settings->yathui;

        if ($settings->check_prefix('display')) {
            my $display = $settings->display;
            if ($yathui->only) {
                $display->renderers = {
                    '@' => ['Test2::Harness::Renderer::UI'],
                    'Test2::Harness::Renderer::UI' => [],
                }
            }
            elsif ($yathui->only_db) {
                $display->renderers = {
                    '@' => ['Test2::Harness::Renderer::UIDB'],
                    'Test2::Harness::Renderer::UIDB' => [],
                }
            }
            elsif ($yathui->render) {
                unless ($display->renderers->{'Test2::Harness::Renderer::UI'}) {
                    push @{$display->renderers->{'@'}} => 'Test2::Harness::Renderer::UI';
                    $display->renderers->{'Test2::Harness::Renderer::UI'} = [];
                }
            }
            elsif ($yathui->db) {
                unless ($display->renderers->{'Test2::Harness::Renderer::UIDB'}) {
                    push @{$display->renderers->{'@'}} => 'Test2::Harness::Renderer::UIDB';
                    $display->renderers->{'Test2::Harness::Renderer::UIDB'} = [];
                }
            }
        }
    };
};

option_group {prefix => 'yathui-db', category => "YathUI Options"} => sub {
    option config => (
        type => 's',
        description => "Module that implements 'MODULE->yath_ui_config(%params)' which should return a Test2::Harness::UI::Config instance.",
    );

    option driver => (
        type => 's',
        description => "DBI Driver to use",
        long_examples => [' Pg', 'mysql', 'MariaDB'],
    );

    option name => (
        type => 's',
        description => 'Name of the database to use for yathui',
    );

    option user => (
        type => 's',
        description => 'Username to use when connecting to the db',
    );

    option pass => (
        type => 's',
        description => 'Password to use when connecting to the db',
    );

    option dsn => (
        type => 's',
        description => 'DSN to use when connecting to the db',
    );

    option host => (
        type => 's',
        description => 'hostname to use when connecting to the db',
    );

    option port => (
        type => 's',
        description => 'port to use when connecting to the db',
    );

    option socket => (
        type => 's',
        description => 'socket to use when connecting to the db',
    );

    option flush_interval => (
        type => 's',
        long_examples => [' 2', ' 1.5'],
        description => 'When buffering DB writes, force a flush when an event is recieved at least N seconds after the last flush.',
    );

    option buffering => (
        type => 's',
        long_examples => [ ' none', ' job', ' diag', ' run' ],
        description => 'Type of buffering to use, if "none" then events are written to the db one at a time, which is SLOW',
        default => 'diag',
    );

    option coverage => (
        type => 'b',
        description => 'Pull coverage data directly from the database (default: off)',
        default => 0,
    );

    option durations => (
        type => 'b',
        description => 'Pull duration data directly from the database (default: off)',
        default => 0,
    );

    option duration_limit => (
        type => 's',
        description => 'Limit the number of runs to look at for durations data (default: 10)',
        default => 25,
    );

    option publisher => (
        type => 's',
        description => 'When using coverage or duration data, only use data uploaded by this user',
    );
};

sub get_coverage_searches {
    my ($plugin, $settings, $changes) = @_;

    my ($changes_exclude_loads, $changes_exclude_opens);
    if ($settings->check_prefix('finder')) {
        my $finder = $settings->finder;
        $changes_exclude_loads = $finder->changes_exclude_loads;
        $changes_exclude_opens = $finder->changes_exclude_opens;
    }

    my @searches;
    for my $source_file (keys %$changes) {
        my $changed_sub_map = $changes->{$source_file};
        my @changed_subs = keys %$changed_sub_map;

        my $search = {'source_file.filename' => $source_file};
        unless ($changed_sub_map->{'*'} || !@changed_subs) {
            my %seen;

            my @inject;
            push @inject => '*'  unless $changes_exclude_loads;
            push @inject => '<>' unless $changes_exclude_opens;

            $search->{'source_sub.subname'} = {'IN' => [grep { !$seen{$_}++} @inject, @changed_subs]};
        }

        push @searches => $search;
    }

    return @searches;
}

sub get_coverage_rows {
    my ($plugin, $settings, $changes) = @_;

    my $ydb = $settings->prefix('yathui-db') or return;
    return unless $ydb->coverage;

    my $config  = config_from_settings($settings);
    my $schema  = $config->schema;
    my $pname   = $settings->yathui->project                            or die "yathui-project is required.\n";
    my $project = $schema->resultset('Project')->find({name => $pname}) or die "Invalid project '$pname'.\n";
    my $run = $project->last_covered_run(user => $ydb->publisher) or return;

    my @searches = $plugin->get_coverage_searches($settings, $changes) or return;
    return $run->expanded_coverages({'-or' => \@searches});
}

my %CATEGORIES = (
    '*'  => 'loads',
    '<>' => 'opens',
);
sub test_map_from_coverage_rows {
    my ($plugin, $coverages) = @_;

    my %tests;
    while (my $cover = $coverages->next()) {
        my $test = $cover->test_filename or next;

        if (my $manager = $cover->manager_package) {
            unless ($tests{$test}) {
                if (eval { require(mod2file($manager)); 1 }) {
                    $tests{$test} = {manager => $manager, subs => [], loads => [], opens => []};
                }
                else {
                    warn "Error loading manager '$manager'. Running entire test '$test'.\nError:\n====\n$@\n====\n";
                    $tests{$test} = 0;
                    next;
                }
            }

            my $cat = $CATEGORIES{$cover->source_subname} // 'subs';
            push @{$tests{$test}->{$cat}} => @{$cover->metadata};
        }
        else {
            $tests{$test} //= 0;
        }
    }

    return \%tests;
}

sub get_coverage_tests {
    my ($plugin, $settings, $changes) = @_;

    my $ydb = $settings->prefix('yathui-db') or return;
    return unless $ydb->coverage;

    my $coverages = $plugin->get_coverage_rows($settings, $changes) or return;

    my $tests = $plugin->test_map_from_coverage_rows($coverages);

    return $plugin->search_entries_from_test_map($tests, $changes, $settings);
}

sub search_entries_from_test_map {
    my ($plugin, $tests, $changes, $settings) = @_;

    my @out;
    for my $test (keys %$tests) {
        my $meta = $tests->{$test};
        my $manager = $meta ? delete $meta->{manager} : undef;

        unless ($meta && $manager) {
            push @out => $test;
            next;
        }

        unless (eval { push @out => [ $test, $manager->test_parameters($test, $meta, $changes, undef, $settings) ]; 1 }) {
            warn "Error processing coverage data for '$test' using manager '$manager'. Running entire test to be safe.\nError:\n====\n$@\n====\n";
            push @out => $test;
        }
    }

    return @out;
}

sub duration_data {
    my ($plugin, $settings) = @_;
    my $ydb = $settings->prefix('yathui-db') or return;
    return unless $ydb->durations;

    my $config = config_from_settings($settings);
    my $schema = $config->schema;
    my $pname   = $settings->yathui->project                            or die "yathui-project is required.\n";
    my $project = $schema->resultset('Project')->find({name => $pname}) or die "Invalid project '$pname'.\n";

    my %args = (user => $ydb->publisher, limit => $ydb->duration_limit);
    if (my $yui = $settings->prefix('yathui')) {
        $args{short}  = $yui->medium_duration;
        $args{medium} = $yui->long_duration;

        # TODO
        #$args{median} = $yui->median_durations;
    }

    return $project->durations(%args);
}

sub grab_rerun {
    my $this = shift;
    my ($rerun, %params) = @_;

    return (0) if $rerun =~ m/\.jsonl(\.gz|\.bz2)?/;

    my $settings    = $params{settings};
    my $only_failed = $params{only_failed};

    my $config  = config_from_settings($settings);
    my $schema  = $config->schema;

    my ($ok, $err, $run);
    if ($rerun eq '1') {
        my $project_name = $settings->yathui->project;
        my $username = $settings->yathui->user // $ENV{USER};
        $ok = eval { $run = $schema->vague_run_search(project_name => $project_name, username => $username); 1 };
        $err = $@;
    }
    elsif (looks_like_uuid($rerun)) {
        $ok = eval { $run = $schema->vague_run_search(source => $rerun); 1 };
        $err = $@;
    }
    else {
        return (0);
    }

    unless ($run) {
        print $ok ? "No previous run found\n" : "Error getting rerun data from yathui database: $err\n";
        return (1);
    }

    print "Re-Running " . ($only_failed ? "failed" : "all") . " tests from run id: " . $run->run_id . "\n";

    my $search = {retry => 0};
    $search->{fail} = 1 if $only_failed;

    my $files = $run->jobs->search(
        $search,
        {join => 'test_file', order_by => 'test_file.filename'},
    );

    my @files;
    while (my $file = $files->next) {
        push @files => $file->file;
    }

    return (1) unless @files;

    return (1, @files);
}

1;
