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

use File::Path qw/remove_tree/;
use File::Spec();
use POSIX qw/strftime/;
use Time::HiRes qw/sleep/;

use Test2::Harness2();
use Test2::Harness2::TestFile();
use Test2::Harness2::Resource::JobCount();
use App::Yath2::LogArchive();
use App::Yath2::LogArchive::Format qw/default_writer_format/;
use App::Yath2::Streamer::Live();
use App::Yath2::OutputManager();
use App::Yath2::Options::Renderer();
use App::Yath2::Util::IPC qw/publish_ipc_file unlink_ipc_file/;
use Scope::Guard ();

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
    'App::Yath2::Options::Harness',
    'App::Yath2::Options::Workspace',
    'App::Yath2::Options::Finder',
    'App::Yath2::Options::IPC',
    'App::Yath2::Options::Logging',
    'App::Yath2::Options::Renderer',
    'App::Yath2::Options::Resource',
    'App::Yath2::Options::Run',
    'App::Yath2::Options::Runner',
    'App::Yath2::Options::Scheduler',
    'App::Yath2::Options::Term',
    'App::Yath2::Options::Tests',
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

    die "No test files supplied.\nUsage: yath test FILE-OR-DIR [...]\n"
        unless @$args;

    # Build the extension filter from --ext / --extensions / --extension
    # (App::Yath2::Options::Finder), defaulting to t and t2. Used only
    # when an arg is a directory; explicit file paths are always
    # accepted regardless of extension. Be defensive: unit tests pass
    # in mock settings objects that may not implement check_group.
    my @ext = qw/t t2/;
    if (eval { $settings->can('check_group') && $settings->check_group('finder') }) {
        @ext = @{ $settings->finder->extensions // [qw/t t2/] };
    }
    my $ext_re = join '|', map { quotemeta } @ext;

    my @files;
    for my $arg (@$args) {
        if (-d $arg) {
            require File::Find;
            File::Find::find(
                {
                    no_chdir => 1,
                    wanted   => sub {
                        return unless -f $_ && -r _;
                        return unless /\.(?:$ext_re)\z/;
                        no strict 'refs';
                        push @files => Test2::Harness2::TestFile->new(file => ${'File::Find::name'});
                    },
                },
                $arg,
            );
            next;
        }
        die "Not a readable test file or directory: $arg\n" unless -f $arg && -r _;
        push @files => Test2::Harness2::TestFile->new(file => $arg);
    }

    die "No test files matched extensions (@ext) under: @$args\n" unless @files;

    my $workdir = $settings->workspace->workdir;

    my $spawn = Test2::Harness2->spawn(
        workdir   => $workdir,
        protocol  => $settings->ipc->protocol,
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

    my $info_path = publish_ipc_file(
        type     => 'nonce',
        settings => $settings,
        spawn    => $spawn,
        workdir  => $workdir,
    );

    my $writer_pid = $$;
    my $ipc_guard  = Scope::Guard::guard(sub {
        unlink_ipc_file($info_path, $writer_pid);
    });

    # Scope::Guard does not fire on signal-driven exits (Perl shortcuts
    # via the C runtime without unwinding scopes). Install handlers so
    # Ctrl-C / TERM still cleans up the IPC info file before the
    # process dies. Each handler unlinks then re-raises with the
    # default disposition so the caller observes a normal signal exit.
    local $SIG{INT}  = sub { unlink_ipc_file($info_path, $writer_pid); $SIG{INT}  = 'DEFAULT'; kill INT  => $$ };
    local $SIG{TERM} = sub { unlink_ipc_file($info_path, $writer_pid); $SIG{TERM} = 'DEFAULT'; kill TERM => $$ };
    local $SIG{HUP}  = sub { unlink_ipc_file($info_path, $writer_pid); $SIG{HUP}  = 'DEFAULT'; kill HUP  => $$ };

    my $queued = $spawn->queue_test_run(files => \@files);
    die "Could not queue run: " . ($queued->{error} // '(no error)') . "\n"
        unless $queued->{ok};
    my $run_id = $queued->{run_id};

    my $om = App::Yath2::OutputManager->new;
    my $renderers = App::Yath2::Options::Renderer->init_renderers($settings);
    $om->add_renderer($_) for @$renderers;

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

    # User-visible logging (-L / --log-file / --log-dir) is handled by
    # the LogArchive write below at end-of-run; nothing to do here.
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
            $om->dispatch($event);
        },
        exit_if => sub { $seen_end ? 1 : 0 },
    );

    $om->end_of_events;

    $om->finish;

    # Unsubscribe + finish while the harness is still up. We only
    # leave the stream loop because we just saw harness_run_end from
    # the service itself, so the service is guaranteed to still be
    # around to accept these requests.
    eval { $spawn->unsubscribe; 1 } or warn $@;

    # Wait for the harness to drain any events still queued for us
    # before we tell it to finish. The has_pending_messages request
    # itself does not count as pending work (its response is queued
    # AFTER the handler returns). Cap at 30 seconds; on timeout we
    # proceed anyway because the run is over and any straggler
    # events at that point are not worth blocking exit on.
    eval { $spawn->wait_until_idle(30); 1 } or warn $@;

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

    # Archive destination resolution:
    #   1. --log-file PATH      use verbatim
    #   2. --log-dir DIR        DIR/<stamp>.yath
    #   3. neither              <stamp>.yath in CWD (today's behaviour;
    #                           t/AI/integration/test_command_loggers.t
    #                           pins the stamp+yath naming)
    # -L on its own is a forward-compat opt-in; it has no effect here
    # because we always produce the archive anyway.
    my $format  = default_writer_format();
    my $stamp   = strftime('%Y%m%d-%H%M%S', localtime);
    my $archive;
    if (eval { $settings->can('check_group') && $settings->check_group('logging') }) {
        my $logging = $settings->logging;
        my $log_file = $logging->file;
        my $log_dir  = $logging->dir;
        if (defined($log_file) && length $log_file) {
            $archive = $log_file;
        }
        elsif (defined($log_dir) && length $log_dir) {
            $archive = File::Spec->catfile($log_dir, "$stamp.yath");
        }
    }
    $archive //= "$stamp.yath";

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
