package App::Yath2::ArtifactReader;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Time::HiRes qw/time/;
use Scalar::Util qw/blessed/;

use Test2::Harness2::Util qw/tinysleep/;
use Test2::Harness2::Util::JSON qw/decode_json/;

use Object::HashBase qw{
    <spawn
    <run_id
    <renderers
    <mode
    +poll_interval
    +started
    +finished
    +emitted_starts
    +job_logs
    +job_events_emitted
    +per_job_complete
    +fallback_used
};

# Modes per IPC_AND_LOGGERS §13.2.
#
#   quiet    - only emit a final run_complete summary event at run end.
#   qvf      - short "job X passed" for passes; replay every event
#              from a failing job's 0.jsonl.
#   verbose  - replay every event from every test's 0.jsonl as each
#              becomes available.
#   default  - the middle-ground mode: per-job pass/fail plus a
#              run_complete summary (qvf without the failure-replay).
my %VALID_MODES = map { $_ => 1 } qw/quiet qvf verbose default/;

sub init {
    my $self = shift;

    croak "'spawn' is required"  unless defined $self->{+SPAWN};
    croak "'run_id' is required" unless defined $self->{+RUN_ID} && length $self->{+RUN_ID};

    my $renderers = $self->{+RENDERERS} // [];
    croak "'renderers' must be an arrayref"
        unless ref($renderers) eq 'ARRAY';
    $self->{+RENDERERS} = $renderers;

    $self->{+MODE}               //= 'default';
    $self->{+POLL_INTERVAL}      //= 0.1;
    $self->{+STARTED}            //= 0;
    $self->{+FINISHED}           //= 0;
    $self->{+EMITTED_STARTS}     //= {};
    $self->{+JOB_LOGS}           //= {};
    $self->{+JOB_EVENTS_EMITTED} //= {};
    $self->{+PER_JOB_COMPLETE}   //= {};
    $self->{+FALLBACK_USED}      //= 0;

    croak "invalid mode '$self->{+MODE}'"
        unless $VALID_MODES{$self->{+MODE}};

    return;
}

# Drive the layer against a live harness: poll run_status and
# list_run_artifacts until the run drains, emitting events to the
# renderers along the way.
sub run {
    my $self = shift;

    $self->_start_of_run;

    my $deadline = time + ($self->{_timeout} // 3600);

    while (1) {
        my $status = $self->_run_status;

        $self->_emit_pending_events($status);

        my $state = ref($status) eq 'HASH' ? ($status->{state} // '') : '';
        my $drained =
              $state eq 'completed'                                                               ? 1
            : $state eq 'running' && !@{$status->{pending} // []} && !@{$status->{running} // []} ? 1
            :                                                                                       0;

        last if $drained;

        die "artifact-reader: timed out waiting for run '$self->{+RUN_ID}'\n"
            if time >= $deadline;

        tinysleep($self->{+POLL_INTERVAL});
    }

    # One final drain to pick up anything the layer hasn't seen yet.
    my $final = $self->_run_status;
    $self->_emit_pending_events($final);

    $self->_end_of_run($final);
    $self->shutdown;

    return $final;
}

# Replay mode: the caller has an extracted log tree (per
# App::Yath2::LogArchive). Feed events to the renderer as if the run
# were live. This mode never talks to an IPC bus.
#
# $root is the path to a logs/ directory (archive extraction root);
# $run_id identifies which run to replay.
sub replay_from_logs {
    my ($class, %args) = @_;

    my $root      = $args{logs_dir} // croak "'logs_dir' is required";
    my $run_id    = $args{run_id}   // croak "'run_id' is required";
    my $renderers = $args{renderers} // [];
    my $mode      = $args{mode}      // 'verbose';

    my $self = $class->new(
        spawn     => bless({_replay => 1}, 'App::Yath2::ArtifactReader::NullSpawn'),
        run_id    => $run_id,
        renderers => $renderers,
        mode      => $mode,
    );

    $self->_start_of_run;

    my $run_dir = "$root/runs/$run_id";
    if (-d $run_dir) {
        opendir(my $dh, $run_dir) or croak "Cannot read $run_dir: $!";
        my @jobs = sort grep { $_ ne 'services' && $_ !~ /^\./ && -d "$run_dir/$_" } readdir $dh;
        closedir $dh;

        for my $job_id (@jobs) {
            my $jsonl = "$run_dir/$job_id/0.jsonl";
            next unless -e $jsonl;
            $self->_replay_job_log($job_id, $jsonl);
        }
    }

    # End-of-run aggregate: the replay has no IPC so we synthesise
    # one from the per-job complete state the layer collected while
    # walking the logs.
    my $summary = $self->_build_replay_summary;
    $self->_end_of_run($summary);
    $self->shutdown;

    return $summary;
}

sub shutdown {
    my $self = shift;
    $_->shutdown for @{$self->{+RENDERERS}};
    return;
}

# -------------------- helpers ----------------------------------------

sub _start_of_run {
    my $self = shift;
    return if $self->{+STARTED};
    $self->{+STARTED} = 1;
    $_->start_of_run(run_id => $self->{+RUN_ID}, mode => $self->{+MODE})
        for @{$self->{+RENDERERS}};
    return;
}

sub _end_of_run {
    my ($self, $status) = @_;
    return if $self->{+FINISHED};
    $self->{+FINISHED} = 1;

    # Build the run_complete payload. Prefer harness-reported counts;
    # fall back to what we've observed per-job.
    my $status_h = ref($status) eq 'HASH' ? $status : {};
    my $pass     = $status_h->{pass_count};
    my $fail     = $status_h->{fail_count};
    $pass //= scalar grep { $_->{pass}  } values %{$self->{+PER_JOB_COMPLETE}};
    $fail //= scalar grep { !$_->{pass} } values %{$self->{+PER_JOB_COMPLETE}};

    my @jobs = values %{$self->{+PER_JOB_COMPLETE}};

    my %summary = (
        run_id     => $self->{+RUN_ID},
        pass_count => $pass // 0,
        fail_count => $fail // 0,
        jobs       => \@jobs,
    );
    $summary{duration} = $status_h->{duration} if defined $status_h->{duration};

    # Synthesise a run_complete event for renderers that subscribe to
    # the event stream (e.g. Default prints a short run-ended line;
    # Summary uses end_of_run itself so this is additive).
    my $event = {
        event_id   => 'artifact-reader-run-complete-' . $self->{+RUN_ID},
        stamp      => time,
        facet_data => {
            harness => {
                run_id       => $self->{+RUN_ID},
                run_complete => \%summary,
            },
        },
    };
    $_->event_in($event) for @{$self->{+RENDERERS}};

    $_->end_of_run(%summary) for @{$self->{+RENDERERS}};

    return;
}

# Dispatch an event to every renderer. Returns nothing; renderers are
# expected to be forgiving of whatever the layer hands them.
sub _dispatch {
    my ($self, $event) = @_;
    $_->event_in($event) for @{$self->{+RENDERERS}};
    return;
}

# Run the state machine forward one step against the current status
# snapshot. Emits per-job start / pass / fail events consistent with
# the layer's mode; in verbose / qvf mode it also replays the job's
# 0.jsonl where available.
sub _emit_pending_events {
    my ($self, $status) = @_;
    return unless ref($status) eq 'HASH';

    my $running = $status->{running} // [];
    my $done    = $status->{done}    // [];

    # job-started events for running ids we haven't announced yet.
    for my $jid (@$running) {
        next if $self->{+EMITTED_STARTS}->{$jid}++;
        next if $self->{+MODE} eq 'quiet';
        $self->_dispatch({
            event_id   => "artifact-reader-start-$jid",
            stamp      => time,
            facet_data => {
                harness => {
                    job_id           => $jid,
                    run_id           => $self->{+RUN_ID},
                    test_job_started => {job_id => $jid, run_id => $self->{+RUN_ID}},
                },
            },
        });
    }

    # Newly-completed jobs: grab the per-run artifact map once we see
    # a new done id, then either emit a short verdict or replay the
    # full 0.jsonl depending on mode.
    my $new_done = [grep { !$self->{+PER_JOB_COMPLETE}->{$_} } @$done];
    if (@$new_done) {
        my $artifacts = $self->_run_artifacts;
        for my $jid (@$new_done) {
            my $verdict = $self->_verdict_for_job($status, $jid);
            my %entry   = (
                job_id => $jid,
                pass   => $verdict,
            );
            my $log = $self->_job_log_from_artifacts($artifacts, $jid);
            $entry{log_file} = $log if defined $log;
            $self->{+PER_JOB_COMPLETE}->{$jid} = \%entry;

            my $should_replay =
                $self->{+MODE} eq 'verbose' ? 1
                : ($self->{+MODE} eq 'qvf' && !$verdict) ? 1
                : 0;

            if ($should_replay && defined $log) {
                $self->_replay_job_log($jid, $log);
            }

            # Short verdict event (skip in quiet mode -- the summary
            # at end_of_run is enough).
            next if $self->{+MODE} eq 'quiet';
            $self->_dispatch({
                event_id   => "artifact-reader-complete-$jid",
                stamp      => time,
                facet_data => {
                    harness => {
                        job_id             => $jid,
                        run_id             => $self->{+RUN_ID},
                        test_job_completed => {
                            job_id => $jid,
                            run_id => $self->{+RUN_ID},
                            pass   => $verdict,
                        },
                    },
                },
            });
        }
    }

    return;
}

sub _verdict_for_job {
    my ($self, $status, $jid) = @_;
    # run_status doesn't give us per-job verdicts directly; infer from
    # pass_count / fail_count order when we can, otherwise fall back to
    # "pass" so the renderer at least sees something. Real per-job
    # verdicts will arrive from richer IPC once the harness exposes
    # them; for now, jobs are assumed to have passed unless the total
    # fail_count is non-zero AND this is the last unaccounted-for job.
    #
    # The fallback path via list_run_final_state (TODO) would give us
    # authoritative per-job verdicts. For now, use the inflight
    # harness counters conservatively.
    my $h_fail = $status->{fail_count} // 0;
    my $already_seen_fails = grep { !$_->{pass} } values %{$self->{+PER_JOB_COMPLETE}};
    return 1 if $h_fail <= $already_seen_fails;
    # Greedy-fail: once failures outnumber what we've already recorded,
    # mark the newcomer as the failing job.
    return 0;
}

sub _job_log_from_artifacts {
    my ($self, $artifacts, $jid) = @_;
    return undef unless ref($artifacts) eq 'HASH';
    return undef unless ref($artifacts->{artifacts}) eq 'HASH';

    # Match by collector entry's job_id, not the opaque collector_id
    # key -- the collector_id convention in §5.4 isn't keyed by
    # job_id alone.
    #
    # The JSONL logger's metadata() reports the file path under
    # 'jsonl_file' (see Test2::Harness2::Collector::Logger::JSONL).
    # 'output_file' is checked as a fallback for future loggers that
    # settle on the generic key. Non-file logger artefacts (DB, HTTP)
    # are skipped.
    for my $cid (keys %{$artifacts->{artifacts}}) {
        my $entry = $artifacts->{artifacts}{$cid};
        next unless ref($entry) eq 'HASH';
        next unless defined $entry->{job_id} && $entry->{job_id} eq $jid;

        # Prefer the canonical JSONL class first.
        for my $class (qw/Test2::Harness2::Collector::Logger::JSONL/) {
            my $list = $entry->{loggers}{$class} // next;
            for my $inst (@$list) {
                next unless ref($inst) eq 'HASH';
                return $inst->{jsonl_file}  if defined $inst->{jsonl_file};
                return $inst->{output_file} if defined $inst->{output_file};
            }
        }
        # Fall back: any file-bearing logger at all.
        for my $class (keys %{$entry->{loggers} // {}}) {
            for my $inst (@{$entry->{loggers}{$class} // []}) {
                next unless ref($inst) eq 'HASH';
                for my $k (qw/jsonl_file output_file json_file/) {
                    return $inst->{$k} if defined $inst->{$k};
                }
            }
        }
    }

    return undef;
}

sub _replay_job_log {
    my ($self, $jid, $path) = @_;
    return unless defined $path && -e $path;
    return if $self->{+JOB_EVENTS_EMITTED}->{$jid}++;

    open(my $fh, '<', $path) or do {
        warn "artifact-reader: cannot open $path for replay: $!";
        return;
    };

    while (my $line = <$fh>) {
        chomp $line;
        next unless length $line;
        my $event = eval { decode_json($line) };
        unless (defined $event) {
            warn "artifact-reader: malformed event in $path: $@";
            next;
        }
        $self->_dispatch($event);
    }
    close $fh;

    return;
}

sub _build_replay_summary {
    my $self = shift;
    my @jobs = values %{$self->{+PER_JOB_COMPLETE}};
    my $pass = grep {  $_->{pass} } @jobs;
    my $fail = grep { !$_->{pass} } @jobs;
    return {
        run_id     => $self->{+RUN_ID},
        pass_count => $pass,
        fail_count => $fail,
        jobs       => \@jobs,
    };
}

sub _run_status {
    my $self = shift;
    my $resp = eval { $self->{+SPAWN}->run_status($self->{+RUN_ID}) };
    return $resp if ref($resp) eq 'HASH';
    # Fall back to get_run_status if the primary handle didn't answer.
    return $self->_fallback_get_run_status;
}

sub _run_artifacts {
    my $self = shift;
    my $resp = eval { $self->{+SPAWN}->list_run_artifacts($self->{+RUN_ID}) };
    return $resp if ref($resp) eq 'HASH';
    return {ok => 0, artifacts => {}};
}

sub _fallback_get_run_status {
    my $self = shift;
    $self->{+FALLBACK_USED} = 1;
    my $resp = eval { $self->{+SPAWN}->get_run_status($self->{+RUN_ID}) };
    return $resp if ref($resp) eq 'HASH';
    return {ok => 0, state => '', pending => [], running => [], done => []};
}

# Placeholder for a replay-only spawn handle used by replay_from_logs
# so that run() can't be called on it (we keep the constructor strict
# with an 'spawn' requirement even in the replay path).
package App::Yath2::ArtifactReader::NullSpawn;

sub run_status         { {ok => 1, state => 'completed', pending => [], running => [], done => []} }
sub list_run_artifacts { {ok => 1, artifacts => {}} }
sub get_run_status     { {ok => 1, state => 'completed', pending => [], running => [], done => []} }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::ArtifactReader - Command-side artifact-reading layer for renderers.

=head1 DESCRIPTION

The sole component in the command that reads artifacts and queries
the harness for state. Sits between C<Test2::Harness2> (via a
L<Test2::Harness2::Spawn> handle) and one or more renderers (each
conforming to L<App::Yath2::Role::Renderer>).

See C<IPC_AND_LOGGERS §13> for the full contract. Summary:

=over 4

=item *

Polls the harness's per-run status (C<run_status>) and, as tests
complete, queries C<list_run_artifacts> to learn where each job's
artifact files live.

=item *

Feeds events to every attached renderer via the renderer's
C<event_in> entry point. No renderer reads files or talks IPC.

=item *

Filters what it sends to the renderer based on the user's mode:

    quiet    - nothing until a final run_complete event at run end.
    qvf      - short verdict per job; replay a failing job's 0.jsonl.
    verbose  - replay every event from every job's 0.jsonl.
    default  - per-job verdicts plus the run_complete summary.

=item *

Falls back to C<get_run_status> when no artifacts are present
(e.g. C<--no-log> runs), synthesising verdicts for the renderer so
it can still print a summary.

=back

The same layer can be pointed at an extracted log archive via
C<replay_from_logs>; there is no live IPC in that path.

=head1 SYNOPSIS

    use App::Yath2::ArtifactReader;
    use App::Yath2::Renderer::Default;
    use App::Yath2::Renderer::Summary;

    my $spawn = Test2::Harness2->spawn(...);
    my $resp  = $spawn->queue_test_run(files => \@files);
    my $rid   = $resp->{run_id};

    my $layer = App::Yath2::ArtifactReader->new(
        spawn     => $spawn,
        run_id    => $rid,
        renderers => [
            App::Yath2::Renderer::Default->new,
            App::Yath2::Renderer::Summary->new,
        ],
        mode      => 'default',
    );

    $layer->run;
    $spawn->finish;
    $spawn->wait;

    # Post-run replay from an extracted archive:
    App::Yath2::ArtifactReader->replay_from_logs(
        logs_dir  => '/extracted/path/logs',
        run_id    => $rid,
        renderers => [App::Yath2::Renderer::Formatter->new],
        mode      => 'verbose',
    );

=head1 ATTRIBUTES

=over 4

=item spawn

A L<Test2::Harness2::Spawn>-shaped handle, exposing
C<run_status>, C<list_run_artifacts>, and C<get_run_status>.

=item run_id

The run to observe.

=item renderers

Arrayref of renderer instances. Each must consume
L<App::Yath2::Role::Renderer>.

=item mode

One of C<quiet>, C<qvf>, C<verbose>, or C<default>. Governs what
the layer forwards to the renderer. Default C<default>.

=item poll_interval

Seconds to sleep between C<run_status> polls. Default 0.1.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
