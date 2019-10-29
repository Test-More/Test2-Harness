package App::Yath::Command::start;
use strict;
use warnings;

our $VERSION = '0.001100';

use App::Yath::Util qw/find_pfile PFILE_NAME/;
use App::Yath::Options;

use Test2::Harness::Run;
use Test2::Harness::Util::Queue;
use Test2::Harness::Util::File::JSON;
use Test2::Harness::IPC;

use Test2::Harness::Util::JSON qw/encode_json decode_json/;
use Test2::Harness::Util qw/mod2file open_file/;
use Test2::Util::Table qw/table/;

use Test2::Harness::Util::IPC qw/run_cmd USE_P_GROUPS/;

use File::Spec;

use Carp qw/croak/;
use File::Path qw/remove_tree/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

include_options(
    'App::Yath::Options::Debug',
    'App::Yath::Options::PreCommand',
    'App::Yath::Options::Runner',
    'App::Yath::Options::Workspace',
);

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

    my $settings = $self->settings;
    my $dir      = $settings->workspace->workdir;

    if (my $exists = find_pfile()) {
        remove_tree($dir, {safe => 1, keep_root => 0});
        die "Persistent harness appears to be running, found $exists\n";
    }

    $self->write_settings_to($dir, 'settings.json');

    my $run_queue = Test2::Harness::Util::Queue->new(file => File::Spec->catfile($dir, 'run_queue.jsonl'));
    $run_queue->start();

    my $pfile = File::Spec->rel2abs(PFILE_NAME(), $ENV{YATH_PERSISTENCE_DIR} // './');

    my $pid = run_cmd(
        #stderr => File::Spec->catfile($dir, 'error.log'),
        #stdout => File::Spec->catfile($dir, 'output.log'),

        command => [
            $^X, $settings->yath->script,
            (map { "-D$_" } @{$settings->yath->dev_libs}),
            '--no-scan-plugins',    # Do not preload any plugin modules
            runner           => $dir,
            monitor_preloads => 1,
            persist          => $pfile,
        ],
    );

    print "\nPersistent runner started!\n";

    print "Runner PID: $pid\n";
    print "Runner dir: $dir\n";
    print "Runner logs:\n";
    print "\nUse `yath watch` to monitor the persistent runner\n\n";

    Test2::Harness::Util::File::JSON->new(name => $pfile)->write({pid => $pid, dir => $dir});

    waitpid($pid, 0);

    return 0;
}

1;
