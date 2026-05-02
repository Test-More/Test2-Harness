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
use App::Yath2::TestFile();
use Test2::Harness2::Util qw/mod2file/;
use App::Yath2::LogArchive();
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
    'App::Yath2::Options::LogArchive',
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

# Standard pair of loggers wired up at every level (harness service,
# per-run service, per-test-job collector). One always streams every
# event as JSONL; the other writes a JSON snapshot file.
use constant DEFAULT_LOGGERS => [
    'Test2::Harness2::Collector::Logger::JSONL',
    'Test2::Harness2::Collector::Logger::JSON',
];

sub args_include_tests { 1 }
sub group              { 'test' }
sub summary            { 'Run a list of test files' }

sub description {
    return <<"    EOT";
Test runner. Pass a list of test files; they are executed via a
Test2::Harness2 child service. Concurrency is governed by the resource
group (--slots / -j, --job-slots / -x, --resource / -R, --no-resource).
Exits 0 if every test passed, non-zero otherwise.
    EOT
}

sub run {
    my $self = shift;

    # Autoflush both streams so any print reaches an interactive user
    # or a CI-captured log immediately.
    local $| = 1;
    STDERR->autoflush(1);

    my $settings = $self->{+SETTINGS};
    my $args     = $self->{+ARGS} // [];

    die "No test files supplied.\nUsage: yath test FILE-OR-DIR [...]\n"
        unless @$args;

    my @files   = $self->_collect_test_files($args);
    my $workdir = $settings->workspace->workdir;
    my $spawn   = $self->_spawn_harness($workdir);

    my ($info_path, $ipc_guard) = $self->_publish_ipc($spawn, $workdir);

    my $run_id = $self->_queue_run($spawn, \@files);

    my ($final_pass, $seen_end) = $self->_drive_streamer($spawn, $workdir, $run_id);

    $self->_shutdown_harness($spawn);

    my $archive = $self->_resolve_archive_path;
    App::Yath2::LogArchive->open(dir => "$workdir/logs")->archive($archive);
    print "Wrote archive: $archive\n";
    App::Yath2::LogArchive->update_last_log_symlink($archive);

    if (!$settings->workspace->keep_dirs) {
        remove_tree($workdir, {error => \my $rm_errors});
        if ($rm_errors && @$rm_errors) {
            for my $e (@$rm_errors) {
                my ($file, $msg) = %$e;
                warn "Could not remove '$file': $msg\n";
            }
        }
    }

    return $final_pass ? 0 : 1;
}

# Walk @args expanding directories via --extensions / -E filter.
# Explicit files are always accepted regardless of extension.
sub _collect_test_files {
    my ($self, $args) = @_;
    my $settings = $self->{+SETTINGS};

    my @ext    = @{$settings->finder->extensions // [qw/t t2/]};
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
                        push @files => App::Yath2::TestFile->new(file => ${'File::Find::name'});
                    },
                },
                $arg,
            );
            next;
        }
        die "Not a readable test file or directory: $arg\n" unless -f $arg && -r _;
        push @files => App::Yath2::TestFile->new(file => $arg);
    }

    die "No test files matched extensions (@ext) under: @$args\n" unless @files;
    return @files;
}

# Spawn the harness service with the resource set the user requested.
# All slot/limiter resolution happened in Options::Resource's
# post-process; we just instantiate the classes that ended up in
# $settings->resource->classes.
sub _spawn_harness {
    my ($self, $workdir) = @_;
    my $settings = $self->{+SETTINGS};

    my @resources = $self->_build_resources;

    return Test2::Harness2->spawn(
        workdir         => $workdir,
        protocol        => $settings->ipc->protocol,
        resources       => \@resources,
        loggers         => DEFAULT_LOGGERS,
        service_loggers => DEFAULT_LOGGERS,
        test_loggers    => DEFAULT_LOGGERS,
    );
}

# Instantiate the resource classes Options::Resource's post-process
# settled on. JobCount is the one class for which this command knows
# the slots / max_per_job mapping (so -j N:M wires through). Other
# classes are constructed with whatever args Options::Resource
# recorded for them.
sub _build_resources {
    my $self = shift;
    my $rg   = $self->{+SETTINGS}->resource;

    my $classes = $rg->classes // {};
    return () unless keys %$classes;    # --no-resource: unlimited

    my @out;
    for my $mod (sort keys %$classes) {
        require(mod2file($mod));
        my @args = @{$classes->{$mod} // []};

        if ($mod eq 'Test2::Harness2::Resource::JobCount' && !@args) {
            push @out => $mod->new(
                slots       => $rg->slots,
                max_per_job => $rg->job_slots,
            );
            next;
        }

        push @out => $mod->new(@args);
    }
    return @out;
}

# Install the SIGINT/TERM/HUP handlers that clean up the IPC info
# file before the publish_ipc_file call -- otherwise a signal
# delivered during the publish would race against the cleanup guard.
# Returns ($info_path, $ipc_guard) for the caller to keep alive.
sub _publish_ipc {
    my ($self, $spawn, $workdir) = @_;
    my $settings = $self->{+SETTINGS};

    my $info_path;
    my $writer_pid = $$;
    my $ipc_guard  = Scope::Guard::guard(sub {
        unlink_ipc_file($info_path, $writer_pid) if defined $info_path;
    });

    # Scope::Guard does not fire on signal-driven exits (Perl
    # shortcuts via the C runtime without unwinding scopes). Install
    # handlers so Ctrl-C / TERM still cleans up before the process
    # dies. Each handler unlinks then re-raises with the default
    # disposition so the caller observes a normal signal exit.
    local $SIG{INT}  = sub { unlink_ipc_file($info_path, $writer_pid) if defined $info_path; $SIG{INT}  = 'DEFAULT'; kill INT  => $$ };
    local $SIG{TERM} = sub { unlink_ipc_file($info_path, $writer_pid) if defined $info_path; $SIG{TERM} = 'DEFAULT'; kill TERM => $$ };
    local $SIG{HUP}  = sub { unlink_ipc_file($info_path, $writer_pid) if defined $info_path; $SIG{HUP}  = 'DEFAULT'; kill HUP  => $$ };

    $info_path = publish_ipc_file(
        command  => 'test',
        settings => $settings,
        spawn    => $spawn,
        workdir  => $workdir,
    );

    return ($info_path, $ipc_guard);
}

# Hand the assembled file list to the harness. --set-hash-seed
# (Options::Tests) flows through verbatim when set.
sub _queue_run {
    my ($self, $spawn, $files) = @_;
    my $settings = $self->{+SETTINGS};

    my %queue_args = (files => $files);
    if (my $hash_seed = $settings->tests->set_hash_seed) {
        $queue_args{hash_seed} = $hash_seed if length $hash_seed;
    }

    my $queued = $spawn->queue_test_run(%queue_args);
    die "Could not queue run: " . ($queued->{error} // '(no error)') . "\n"
        unless $queued->{ok};

    return $queued->{run_id};
}

# Stream live events through the OutputManager + renderer chain.
# The streamer's harness_run_end event is the authoritative "run is
# over" signal, carrying the pass/fail verdict.
sub _drive_streamer {
    my ($self, $spawn, $workdir, $run_id) = @_;
    my $settings = $self->{+SETTINGS};

    my $om        = App::Yath2::OutputManager->new;
    my $renderers = App::Yath2::Options::Renderer->init_renderers($settings);
    $om->add_renderer($_) for @$renderers;

    my $streamer = App::Yath2::Streamer::Live->new(
        handle => $spawn,
        run    => $run_id,
        log    => "$workdir/logs",
        global => 1,
    );

    my ($final_pass, $seen_end);
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

    # Drop the streamer reference here, before _shutdown_harness
    # tears down $spawn -- otherwise the streamer's hold on the IPC
    # handle keeps the AtomicPipe alive past workdir cleanup.
    undef $streamer;

    return ($final_pass, $seen_end);
}

# Unsubscribe + drain pending messages while the harness is still
# alive, then ask it to finish and reap. Order matters: we only
# leave _drive_streamer because we saw harness_run_end, so the
# service is guaranteed to still be around to accept these requests.
sub _shutdown_harness {
    my ($self, $spawn) = @_;

    eval { $spawn->unsubscribe; 1 } or warn $@;

    # Drain stragglers, but cap the wait. The has_pending_messages
    # request itself does not count as pending work (its response
    # is queued AFTER the handler returns). 30s is generous.
    eval { $spawn->wait_until_idle(30); 1 } or warn $@;

    $spawn->finish;
    $spawn->wait;
}

# Resolve the archive's destination path:
#   --log-file PATH  use verbatim
#   --log-dir DIR    DIR/<stamp>.yath
#   neither          ${TMPDIR}/${project}-${user}-${stamp}-${pid}.yath
sub _resolve_archive_path {
    my $self = shift;
    my $settings = $self->{+SETTINGS};

    my $logging = $settings->log_archive;
    if (my $log_file = $logging->file) {
        return $log_file if length $log_file;
    }

    my $stamp = strftime('%Y%m%d-%H%M%S', localtime);
    if (my $log_dir = $logging->dir) {
        return File::Spec->catfile($log_dir, "$stamp.yath") if length $log_dir;
    }

    my $project = $settings->yath->project // '__UNKNOWN__';
    my $user    = $settings->yath->user    // 'unknown';
    return File::Spec->catfile(
        File::Spec->tmpdir(),
        "$project-$user-$stamp-$$.yath",
    );
}

1;

__END__

=head1 POD IS AUTO-GENERATED
