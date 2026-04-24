package App::Yath2::Command::test;
use strict;
use warnings;

our $VERSION = '2.000011';

use Object::HashBase qw{
    <settings
    <args
    <env_vars
    <option_state
    <plugins
};

use File::Spec();
use File::Path qw/remove_tree/;
use Carp qw/croak/;
use POSIX qw/strftime/;
use Time::HiRes qw/sleep/;

use Test2::Harness2();
use Test2::Harness2::TestFile();
use Test2::Harness2::Resource::JobCount();
use App::Yath2::LogArchive();
use App::Yath2::LogArchive::Format qw/default_writer_format/;
use App::Yath2::Streamer::Live();

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Workspace',
    'App::Yath2::Options::Yath',
);

use Role::Tiny::With;
with 'App::Yath2::Role::Command';

sub args_include_tests { 1 }
sub group              { 'test' }
sub summary            { 'Run a list of test files' }

sub description {
    return <<"    EOT";
Minimal test runner. Pass a list of test files; they are executed via a
Test2::Harness2 child service with 16-slot job concurrency. Exits 0 if every
test passed, non-zero otherwise. The pass/fail verdict is retrieved from the
harness service via IPC -- log files are not consulted.
    EOT
}

sub run {
    my $self = shift;

    # Autoflush both streams so any print reaches an interactive user
    # or a CI-captured log immediately instead of sitting in Perl's
    # default block buffer until the process exits.
    local $| = 1;
    STDERR->autoflush(1);

    my $settings = $self->{+SETTINGS};
    my $args     = $self->{+ARGS} // [];

    die "No test files supplied.\nUsage: yath test FILE [FILE ...]\n"
        unless @$args;

    my @files;
    for my $file (@$args) {
        die "Not a readable test file: $file\n" unless -f $file && -r _;
        push @files => Test2::Harness2::TestFile->new(file => $file);
    }

    my $workdir = $settings->workspace->workdir;

    my $spawn = Test2::Harness2->spawn(
        workdir   => $workdir,
        resources => [Test2::Harness2::Resource::JobCount->new(slots => 16)],
        loggers   => [
            'Test2::Harness2::Collector::Logger::JSONL',
            'Test2::Harness2::Collector::Logger::JSON',
        ],
        service_loggers => [
            'Test2::Harness2::Collector::Logger::JSONL',
            'Test2::Harness2::Collector::Logger::JSON',
        ],
        test_loggers => [
            'Test2::Harness2::Collector::Logger::JSONL',
            'Test2::Harness2::Collector::Logger::JSON',
        ],
    );

    my $queued = $spawn->queue_test_run(files => \@files);
    die "Could not queue run: " . ($queued->{error} // '(no error)') . "\n"
        unless $queued->{ok};
    my $run_id = $queued->{run_id};

    # Stream events synthesized from the harness's IPC state updates
    # (plus any general events its loggers record) and print them as
    # JSON lines to stdout. The stream's own harness_run_end event is
    # the authoritative "run is over" signal: it carries the pass /
    # pass_count / fail_count verdict, so we do not need to poll
    # run_results at all. Polling a sync_request during harness
    # shutdown was the source of the old "peer went away" race; by
    # leaning entirely on the subscription stream we never issue a
    # request to a service that may have started to close out.
    my $streamer = App::Yath2::Streamer::Live->new(
        handle => $spawn,
        run    => $run_id,
        log    => "$workdir/logs",
        global => 1,
    );

    my $final_pass;
    my $seen_end;
    $streamer->stream(
        callback => sub {
            my ($event) = @_;
            my $fd = $event->facet_data // {};
            if (my $end = $fd->{harness_run_end}) {
                $seen_end   = 1;
                $final_pass = $end->{pass};
            }
            print $event->as_json, "\n";
        },
        exit_if => sub { $seen_end ? 1 : 0 },
    );

    # Unsubscribe + finish while the harness is still up. We only
    # leave the stream loop because we just saw harness_run_end from
    # the service itself, so the service is guaranteed to still be
    # around to accept these requests.
    eval { $spawn->unsubscribe; 1 } or warn $@;

    # Drop the streamer explicitly: it holds a reference to $spawn,
    # which is what keeps the IPC handle (and its AtomicPipe client)
    # alive. Without this, the client's pre_disconnect_hook fires
    # later during run()'s scope teardown -- AFTER remove_tree has
    # already nuked the workdir, making the fifo unlink warn.
    undef $streamer;

    $spawn->finish;
    $spawn->wait;

    undef $spawn;

    # Hold onto the workdir until we have archived its logs ourselves.
    $settings->workspace->create_option(keep_dirs => 1);

    my $format  = default_writer_format();
    my $archive = strftime('%Y%m%d-%H%M%S', localtime) . '.yath';
    App::Yath2::LogArchive->create(
        source => "$workdir/logs",
        path   => $archive,
        format => $format,
    );
    print "Wrote archive: $archive (format: $format)\n";

    remove_tree($workdir, {error => \my $rm_errors});
    if ($rm_errors && @$rm_errors) {
        for my $e (@$rm_errors) {
            my ($file, $msg) = %$e;
            warn "Could not remove '$file': $msg\n";
        }
    }

    return $final_pass ? 0 : 1;
}

1;

__END__

=head1 POD IS AUTO-GENERATED
