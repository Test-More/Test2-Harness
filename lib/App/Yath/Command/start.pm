package App::Yath::Command::start;
use strict;
use warnings;

our $VERSION = '1.000152';

use App::Yath::Util qw/find_pfile/;
use App::Yath::Options;

use Test2::Harness::State;
use Test2::Harness::Run;
use Test2::Harness::Util::Queue;
use Test2::Harness::Util::File::JSON;
use Test2::Harness::IPC;

use Test2::Harness::Util::JSON qw/encode_json decode_json/;
use Test2::Harness::Util qw/mod2file open_file parse_exit clean_path/;
use Test2::Util::Table qw/table/;

use Test2::Harness::Util::IPC qw/run_cmd USE_P_GROUPS/;

use POSIX;
use File::Spec;
use Sys::Hostname qw/hostname/;

use Time::HiRes qw/sleep/;

use Carp qw/croak/;
use File::Path qw/remove_tree/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

include_options(
    'App::Yath::Options::Debug',
    'App::Yath::Options::PreCommand',
    'App::Yath::Options::Runner',
    'App::Yath::Options::Workspace',
    'App::Yath::Options::Persist',
    'App::Yath::Options::Collector',
);

option_group {prefix => 'runner', category => "Persistent Runner Options"} => sub {
    option reload => (
        short => 'r',
        type  => 'b',
        description => "Attempt to reload modified modules in-place, restarting entire stages only when necessary.",
        default => 0,
    );

    option restrict_reload => (
        type => 'D',
        long_examples  => ['', '=path'],
        short_examples => ['', '=path'],
        description => "Only reload modules under the specified path, if no path is specified look at anything under the .yath.rc path, or the current working directory.",

        normalize => sub { $_[0] eq '1' ? $_[0] : clean_path($_[0]) },
        action    => \&restrict_action,
    );

    option quiet => (
        short       => 'q',
        type        => 'c',
        description => "Be very quiet.",
        default     => 0,
    );
};

sub restrict_action {
    my ($prefix, $field, $raw, $norm, $slot, $settings) = @_;

    if ($norm eq '1') {
        my $hset = $settings->harness;
        my $path = $hset->config_file || $hset->cwd;
        $path //= do { require Cwd; Cwd::getcwd() };
        $path =~ s{\.yath\.rc$}{}g;
        push @{$$slot} => $path;
    }
    else {
        push @{$$slot} => $norm;
    }
}

sub MAX_ATTACH() { 1_048_576 }

sub group { 'persist' }

sub always_keep_dir { 1 }

sub summary { "Start the persistent test runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
This command is used to start a persistant instance of yath. A persistant
instance is useful because it allows you to preload modules in advance,
reducing start time for any tests you decide to run as you work.

A running instance will watch for changes to any preloaded files, and restart
itself if anything changes. Changed files are blacklisted for subsequent
reloads so that reloading is not a frequent occurence when editing the same
file over and over again.
    EOT
}

sub run {
    my $self = shift;

    $ENV{TEST2_HARNESS_NO_WRITE_TEST_INFO} //= 1;

    my $settings = $self->settings;
    my $dir      = $settings->workspace->workdir;

    my $pfile = find_pfile($settings, vivify => 1, no_checks => 1);

    if (-f $pfile) {
        remove_tree($dir, {safe => 1, keep_root => 0});
        die "Persistent harness appears to be running, found $pfile\n";
    }

    my $all_state = Test2::Harness::State->new(
        workdir => $dir,
        settings => $settings,
    );
    $all_state->transaction(w => sub { 1 });

    my $run_queue = Test2::Harness::Util::Queue->new(file => File::Spec->catfile($dir, 'run_queue.jsonl'));
    $run_queue->start();

    $self->setup_plugins();
    $self->setup_resources();

    my $stderr = File::Spec->catfile($dir, 'error.log');
    my $stdout = File::Spec->catfile($dir, 'output.log');

    my @prof;
    if ($settings->runner->nytprof) {
        push @prof => '-d:NYTProf';
    }

    my $pid = run_cmd(
        stderr => $stderr,
        stdout => $stdout,

        no_set_pgrp => !$settings->runner->daemon,

        command => [
            $^X, @prof, $settings->harness->script,
            (map { "-D$_" } @{$settings->harness->dev_libs}),
            '--no-scan-plugins',    # Do not preload any plugin modules
            runner           => $dir,
            monitor_preloads => 1,
            persist          => $pfile,
            jobs_todo        => 0,
        ],
    );

    unless ($settings->runner->quiet) {
        print "\nPersistent runner started!\n";

        print "Runner PID: $pid\n";
        print "Runner dir: $dir\n";
        print "\nUse `yath watch` to monitor the persistent runner\n\n" if $settings->runner->daemon;
    }

    Test2::Harness::Util::File::JSON->new(name => $pfile)->write({
        pid      => $pid,
        dir      => $dir,
        version  => $VERSION,
        user     => $ENV{USER},
        hostname => hostname(),
    });

    return 0 if $settings->runner->daemon;

    $SIG{TERM} = sub { kill(TERM => $pid) };
    $SIG{INT}  = sub { kill(INT  => $pid) };

    my $err_fh = open_file($stderr, '<');
    my $out_fh = open_file($stdout, '<');

    while (1) {
        my $out = waitpid($pid, WNOHANG);
        my $wstat = $?;

        my $count = 0;
        while (my $line = <$out_fh>) {
            $count++;
            print STDOUT $line;
        }
        while (my $line = <$err_fh>) {
            $count++;
            print STDERR $line;
        }

        sleep(0.02) unless $out || $count;

        next if $out == 0;
        return 255 if $out < 0;

        my $exit = parse_exit($?);
        return $exit->{err} || $exit->{sig} || 0;
    }
}

1;

__END__

=head1 POD IS AUTO-GENERATED

