package App::Yath2::Streamer;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Basename qw/dirname/;
use File::Path qw/make_path/;
use File::Temp qw/tempdir/;
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time sleep/;
use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Event;
use Test2::Harness2::Util qw/load_module/;
use Test2::Harness2::Util::File::JSON;
use Test2::Harness2::Util::JSON qw/decode_json/;

use Object::HashBase qw{
    <handle
    <log
    <global
    <run
    <runs
    +known_states
    +known_artifacts
    +pending_actions
    +event_queue
    +state_readers
    +event_readers
    +seen_run_start
    +seen_run_end
    +mode
    +exit_requested
    +archive
    +archive_tmpdir
    +archive_extracted
};

# Gate optional modules: Linux::Inotify2 is a nice-to-have for replace
# style logs, IO::Select is core but we still gate the presence so the
# constant pattern in the codebase stays consistent.
use constant HAS_INOTIFY => !!eval { require Linux::Inotify2; 1 };
use constant HAS_IO_SELECT => !!eval { require IO::Select; 1 };

sub init {
    my $self = shift;

    my $handle = $self->{+HANDLE};
    my $log    = $self->{+LOG};

    croak "Either 'handle' or 'log' is required"
        unless defined $handle || defined $log;

    if (defined $handle) {
        croak "'handle' must be an object that supports subscribe()/unsubscribe()"
            unless blessed($handle) && $handle->can('subscribe');
    }

    if (defined $log) {
        croak "'log' must be an existing path" unless -e $log;
    }

    $self->{+MODE} = defined $handle ? 'live' : 'static';

    my @runs;
    push @runs => $self->{+RUN}      if defined $self->{+RUN};
    push @runs => @{$self->{+RUNS}}  if ref($self->{+RUNS}) eq 'ARRAY';
    my %seen;
    @runs = grep { !$seen{$_}++ } @runs;
    $self->{+RUNS} = \@runs;

    croak "At least one of 'global', 'run', or 'runs' must be provided"
        unless $self->{+GLOBAL} || @runs;

    $self->{+KNOWN_STATES}    = {};
    $self->{+KNOWN_ARTIFACTS} = {};
    $self->{+PENDING_ACTIONS} = {};
    $self->{+EVENT_QUEUE}     = [];
    $self->{+STATE_READERS}   = {};
    $self->{+EVENT_READERS}   = {};
    $self->{+SEEN_RUN_START}  = {};
    $self->{+SEEN_RUN_END}    = {};
    $self->{+EXIT_REQUESTED}  = 0;

    # Live mode: subscribe up front so no events get lost after
    # queue_test_run. The harness will push initial snapshots
    # synchronously so we pick them up on the next poll.
    if ($self->{+MODE} eq 'live') {
        $self->{+HANDLE}->subscribe(
            ($self->{+GLOBAL}            ? (global    => 1)          : ()),
            (@runs                       ? (runs      => [@runs])    : ()),
            state     => 1,
            artifacts => 1,
        );
    }

    # Static mode: build reader table from artifacts.json up front.
    # Live mode: artifacts arrive via IPC so we do nothing here.
    $self->_bootstrap_static if $self->{+MODE} eq 'static';

    return;
}

# ----------------------------------------------------------------------
# Public API

sub stream {
    my $self = shift;
    my %params = @_;

    my $callback = $params{callback}
        or croak "'callback' coderef is required";
    croak "'callback' must be a coderef" unless ref($callback) eq 'CODE';

    my $exit_if = $params{exit_if};
    croak "'exit_if' must be a coderef"
        if defined $exit_if && ref($exit_if) ne 'CODE';

    while (1) {
        my $event = $self->next;
        if (defined $event) {
            $callback->($event);
            next;
        }

        last if $self->{+EXIT_REQUESTED};
        last if $exit_if && $exit_if->();

        # No event now, no exit: wait a short beat.
        sleep 0.05;
    }

    # Final drain after exit requested: loop pulls already-queued
    # events + whatever _tick produces one more time. next() returns
    # undef when nothing left.
    $self->{+EXIT_REQUESTED} = 1;
    $self->_tick;
    while (defined(my $event = $self->next)) {
        $callback->($event);
    }

    return;
}

sub next {
    my $self = shift;

    return shift @{$self->{+EVENT_QUEUE}}
        if @{$self->{+EVENT_QUEUE}};

    $self->_tick;

    return shift @{$self->{+EVENT_QUEUE}}
        if @{$self->{+EVENT_QUEUE}};

    return undef;
}

# Called by test commands / external consumers to trigger the final
# drain pass once they know the run is done.
sub request_exit { $_[0]->{+EXIT_REQUESTED} = 1 }

# ----------------------------------------------------------------------
# Tick: pull any new input and convert into events.
sub _tick {
    my $self = shift;

    if ($self->{+MODE} eq 'live') {
        $self->_tick_live;
    }
    else {
        $self->_tick_static;
    }

    return;
}

sub _tick_live {
    my $self = shift;

    my $handle = $self->{+HANDLE}->handle;  # underlying IPC::Manager::Service::Handle

    # Non-blocking poll. Handle may have messages already; otherwise
    # returns immediately.
    $handle->poll(0);

    for my $msg ($handle->messages) {
        my $content = $msg->content;
        next unless ref($content) eq 'HASH';
        $self->_ingest_message($content);
    }

    return;
}

sub _ingest_message {
    my ($self, $content) = @_;

    my $type = $content->{type} or return;

    if ($type eq 'state' && $content->{item} && $content->{item} eq 'run') {
        my $run_id = $content->{run_id};
        my $state  = $content->{state};
        return unless defined $run_id && ref($state) eq 'HASH';
        $self->_apply_run_state($run_id, $state);
        return;
    }

    if ($type eq 'artifacts') {
        my $item      = $content->{item} // 'harness';
        my $run_id    = $content->{run_id};
        my $artifacts = $content->{artifacts};
        return unless ref($artifacts) eq 'HASH';
        $self->_apply_artifacts($item, $run_id, $artifacts);
        return;
    }

    return;
}

# ----------------------------------------------------------------------
# State synthesis. Given a fresh Run snapshot, diff against the last
# known state for the same run and emit any lifecycle events for the
# transitions.
sub _apply_run_state {
    my ($self, $run_id, $state) = @_;

    my $prior = $self->{+KNOWN_STATES}->{$run_id};
    $self->{+KNOWN_STATES}->{$run_id} = $state;

    # run_start is the first event for a run.
    unless ($self->{+SEEN_RUN_START}->{$run_id}) {
        $self->{+SEEN_RUN_START}->{$run_id} = 1;
        $self->_enqueue_event(
            run_id     => $run_id,
            stamp      => $state->{created_at} // time,
            facet_data => {
                harness_run => _harness_run_facet($state),
            },
        );
    }

    my $prior_results = ($prior && ref($prior->{results}) eq 'HASH') ? $prior->{results} : {};
    my $results       = ref($state->{results}) eq 'HASH' ? $state->{results} : {};

    # Walk jobs in a stable order: by queued_at stamp then job_id.
    my @jobs =
        sort {
            (($results->{$a}{queued_at} // 0) <=> ($results->{$b}{queued_at} // 0))
                || ($a cmp $b)
        }
        keys %$results;

    for my $jid (@jobs) {
        my $now   = $results->{$jid};
        my $was   = $prior_results->{$jid};

        # queued -> seen for the first time
        if (!$was && defined $now->{queued_at}) {
            $self->_enqueue_event(
                run_id     => $run_id,
                job_id     => $jid,
                job_try    => $now->{job_try} // 0,
                stamp      => $now->{queued_at},
                facet_data => {
                    harness_job_queued => {
                        job_id   => $jid,
                        file     => $now->{abs_file},
                        abs_file => $now->{abs_file},
                        rel_file => $now->{rel_file},
                        stamp    => $now->{queued_at},
                    },
                },
            );
        }

        # started_at transitions: emit once when it first appears
        if (defined $now->{started_at} && !($was && defined $was->{started_at})) {
            $self->_enqueue_event(
                run_id     => $run_id,
                job_id     => $jid,
                job_try    => $now->{job_try} // 0,
                stamp      => $now->{started_at},
                facet_data => {
                    harness_job_start => {
                        job_id   => $jid,
                        file     => $now->{abs_file},
                        abs_file => $now->{abs_file},
                        rel_file => $now->{rel_file},
                        stamp    => $now->{started_at},
                        details  => "Launched " . ($now->{rel_file} // $jid) . " as job $jid.",
                    },
                },
            );
        }

        # completed_at transitions: emit once when it first appears
        if (defined $now->{completed_at} && !($was && defined $was->{completed_at})) {
            $self->_enqueue_event(
                run_id     => $run_id,
                job_id     => $jid,
                job_try    => $now->{job_try} // 0,
                stamp      => $now->{completed_at},
                facet_data => {
                    harness_job_end => {
                        job_id   => $jid,
                        file     => $now->{abs_file} // $now->{file},
                        abs_file => $now->{abs_file},
                        rel_file => $now->{rel_file},
                        fail     => $now->{pass} ? 0 : 1,
                        stamp    => $now->{completed_at},
                        (defined $now->{exit}  ? (exit  => $now->{exit})  : ()),
                        (defined $now->{codes} ? (codes => $now->{codes}) : ()),
                    },
                    harness_job_exit => {
                        job_id => $jid,
                        (defined $now->{exit}  ? (exit  => $now->{exit})  : ()),
                        (defined $now->{codes} ? (codes => $now->{codes}) : ()),
                        stamp  => $now->{completed_at},
                    },
                },
            );
        }
    }

    # run_end: emitted when the run reports complete state (either the
    # harness has wrapped it up or the snapshot says so explicitly).
    my $complete =
           (defined $state->{state} && $state->{state} eq 'complete')
        || (ref($state->{pending}) eq 'ARRAY' && ref($state->{running}) eq 'ARRAY'
            && !@{$state->{pending}} && !@{$state->{running}} && %$results);

    if ($complete && !$self->{+SEEN_RUN_END}->{$run_id}) {
        $self->{+SEEN_RUN_END}->{$run_id} = 1;

        my $stamp = _max_completed_at($results) // time;
        $self->_enqueue_event(
            run_id     => $run_id,
            stamp      => $stamp,
            facet_data => {
                harness_run_end => _harness_run_end_facet($run_id, $state),
                harness_run     => _harness_run_facet($state),
            },
        );
    }

    return;
}

sub _apply_artifacts {
    my ($self, $item, $run_id, $artifacts) = @_;

    my $scope = $item eq 'harness' ? 'harness' : "run:$run_id";
    my $known = $self->{+KNOWN_ARTIFACTS}->{$scope} //= {};

    my $changed = 0;
    for my $path (keys %$artifacts) {
        next if exists $known->{$path};
        $known->{$path} = $artifacts->{$path};
        $changed++;
    }

    # Resolve any pending actions that were blocked on an artifact
    # that has just arrived. First iteration has no such actions but
    # the slot exists for forward compat.
    if ($changed && $self->{+PENDING_ACTIONS}->{$scope}) {
        my @actions = @{delete $self->{+PENDING_ACTIONS}->{$scope}};
        for my $a (@actions) {
            $a->($self, $known);
        }
    }

    return;
}

# ----------------------------------------------------------------------
# Static archive mode. Synthesize events from the final snapshot(s) and
# general-event log streams recorded on disk.
sub _bootstrap_static {
    my $self = shift;

    # Accept either a log directory (typically $workdir/logs) or a
    # .yath archive file. Both are consumed via LogArchive -- the
    # Directory backend handles the directory form, the Tar / Zip /
    # SevenZip backends handle archives. Files from archives are
    # extracted lazily (only what the streamer actually reads) into
    # a private tempdir; directory input returns its own paths
    # directly.
    require App::Yath2::LogArchive;

    my $log = $self->{+LOG};
    croak "Static streamer requires a directory or log archive; got '$log'"
        unless -d $log || -f $log;

    my $archive = App::Yath2::LogArchive->new(path => $log);
    $self->{+ARCHIVE}           = $archive;
    $self->{+ARCHIVE_EXTRACTED} = {};

    my @runs = @{$self->{+RUNS} // []};

    # Validate requested runs against the archive's run list.
    my %known = map { $_ => 1 } $archive->runs;
    for my $rid (@runs) {
        croak "unknown run '$rid' in '$log'"
            unless $known{$rid};
    }

    for my $rid (@runs) {
        my $scope_map = $archive->artifacts($rid);
        my $state     = $self->_collect_static_state($scope_map);
        $self->_apply_run_state($rid, $state) if $state;

        $self->_setup_static_event_readers($scope_map);
    }

    return;
}

# Resolve an artifact's relative path to a local filesystem path.
# Directory input: returns $LOG/$rel directly (no extraction).
# Archive input: extracts the single file into a private tempdir the
# first time it is asked for, caches the resulting path, and returns
# the cached path on subsequent calls.
sub _resolve_path {
    my ($self, $rel) = @_;

    my $archive = $self->{+ARCHIVE};
    if ($archive->isa('App::Yath2::LogArchive::Directory')) {
        my $abs = "$self->{+LOG}/$rel";
        return -e $abs ? $abs : undef;
    }

    return $self->{+ARCHIVE_EXTRACTED}->{$rel}
        if exists $self->{+ARCHIVE_EXTRACTED}->{$rel};

    return undef unless $archive->has_file($rel);

    my $tmpdir = $self->{+ARCHIVE_TMPDIR} //=
        tempdir('yath-streamer-XXXXXX', TMPDIR => 1, CLEANUP => 1);

    my $abs = "$tmpdir/$rel";
    my $dir = dirname($abs);
    make_path($dir) unless -d $dir;

    my $in = $archive->read_file($rel);
    open(my $out, '>', $abs) or croak "Could not open '$abs' for write: $!";
    binmode $in;
    binmode $out;
    my $buf;
    while (my $n = read $in, $buf, 8192) {
        print {$out} $buf;
    }
    close $in;
    close $out or croak "Could not close '$abs': $!";

    return $self->{+ARCHIVE_EXTRACTED}->{$rel} = $abs;
}

# Collect the state snapshot for a run by asking every logger whose
# records_state() is true for its fetch_state. Reconcile across
# loggers: cared-about fields must agree when both loggers set them.
sub _collect_static_state {
    my ($self, $scope_map) = @_;

    my @state_snapshots;
    for my $rel (keys %$scope_map) {
        my $class = $scope_map->{$rel};
        my $loaded = eval { load_module($class); 1 };
        next unless $loaded;
        next unless $class->can('records_state') && $class->records_state;

        my $path = $self->_resolve_path($rel) or next;

        my $reader = $class->log_reader($path);
        my $state  = $class->fetch_state($reader);
        next unless ref($state) eq 'HASH';

        push @state_snapshots => [$class, $state];
    }

    return undef unless @state_snapshots;

    # Merge: take the first snapshot as the base, then cross-check
    # cared-about keys against each subsequent one. Disagreements on
    # cared-about keys throw.
    my ($base_class, $base) = @{$state_snapshots[0]};
    for my $i (1 .. $#state_snapshots) {
        my ($class, $other) = @{$state_snapshots[$i]};
        _assert_states_agree($base_class, $base, $class, $other);
    }

    return $base;
}

sub _setup_static_event_readers {
    my ($self, $scope_map) = @_;

    for my $rel (keys %$scope_map) {
        my $class = $scope_map->{$rel};
        my $loaded = eval { load_module($class); 1 };
        next unless $loaded;
        next unless $class->can('records_general_events') && $class->records_general_events;

        my $path = $self->_resolve_path($rel) or next;

        my $reader = $class->log_reader($path);
        push @{$self->{+EVENT_READERS}->{$rel}} => [$class, $reader];
    }

    return;
}

sub _tick_static {
    my $self = shift;

    # General-event pass-through: poll each reader once, append what we
    # get to the event queue.
    for my $rel (keys %{$self->{+EVENT_READERS}}) {
        for my $pair (@{$self->{+EVENT_READERS}->{$rel}}) {
            my ($class, $reader) = @$pair;
            next unless $class->ready($reader);
            my @events = $class->fetch_events($reader);
            for my $hash (@events) {
                next unless ref($hash) eq 'HASH';
                push @{$self->{+EVENT_QUEUE}} => $self->_bless_event($hash);
            }
        }
    }

    # In static mode all state was resolved at bootstrap time; the
    # tick therefore has nothing more to do once general events are
    # drained. Once nothing is queued, the caller stops.
    return;
}

# ----------------------------------------------------------------------
# Helpers

sub _enqueue_event {
    my ($self, %fields) = @_;
    push @{$self->{+EVENT_QUEUE}} => $self->_bless_event(\%fields);
    return;
}

sub _bless_event {
    my ($self, $hash) = @_;

    return $hash if blessed($hash) && $hash->isa('Test2::Harness2::Event');

    my %copy = %$hash;
    $copy{event_id}   //= gen_uuid();
    $copy{stamp}      //= time;
    $copy{facet_data} //= {};

    return Test2::Harness2::Event->new(\%copy);
}

sub _harness_run_facet {
    my ($state) = @_;
    return {
        run_id => $state->{run_id},
        (defined $state->{created_at} ? (created_at => $state->{created_at}) : ()),
        (ref($state->{pending}) eq 'ARRAY' ? (pending => [@{$state->{pending}}]) : ()),
        (ref($state->{running}) eq 'ARRAY' ? (running => [@{$state->{running}}]) : ()),
        (ref($state->{done})    eq 'ARRAY' ? (done    => [@{$state->{done}}])    : ()),
    };
}

sub _harness_run_end_facet {
    my ($run_id, $state) = @_;

    my $results = ref($state->{results}) eq 'HASH' ? $state->{results} : {};
    my $all_pass = 1;
    my ($fail_count, $pass_count) = (0, 0);
    for my $jid (keys %$results) {
        next unless defined $results->{$jid}{completed_at};
        if ($results->{$jid}{pass}) { $pass_count++ }
        else                        { $fail_count++; $all_pass = 0 }
    }

    return {
        run_id     => $run_id,
        pass       => $all_pass ? 1 : 0,
        pass_count => $pass_count,
        fail_count => $fail_count,
        stamp      => _max_completed_at($results) // time,
    };
}

sub _max_completed_at {
    my ($results) = @_;
    my $max;
    for my $jid (keys %$results) {
        my $t = $results->{$jid}{completed_at};
        next unless defined $t;
        $max = $t if !defined $max || $t > $max;
    }
    return $max;
}

sub _assert_states_agree {
    my ($class_a, $a, $class_b, $b) = @_;

    my @cared = qw/run_id created_at pending running done/;
    for my $k (@cared) {
        next unless exists $a->{$k} && exists $b->{$k};
        _same_scalar_or_list($a->{$k}, $b->{$k})
            or croak "state loggers disagree on '$k' ($class_a vs $class_b)";
    }

    # results: for each job_id present in both, agree on the
    # cared-about per-job keys.
    my $ra = ref($a->{results}) eq 'HASH' ? $a->{results} : {};
    my $rb = ref($b->{results}) eq 'HASH' ? $b->{results} : {};
    my @jids = do { my %s; $s{$_}++ for keys %$ra, keys %$rb; keys %s };

    for my $jid (@jids) {
        my $ja = $ra->{$jid} or next;
        my $jb = $rb->{$jid} or next;
        for my $k (qw/queued_at started_at completed_at pass exit rel_file abs_file file/) {
            next unless defined $ja->{$k} && defined $jb->{$k};
            _same_scalar_or_list($ja->{$k}, $jb->{$k})
                or croak "state loggers disagree on results.$jid.$k ($class_a vs $class_b)";
        }
    }

    return 1;
}

sub _same_scalar_or_list {
    my ($a, $b) = @_;

    my $ra = ref $a;
    my $rb = ref $b;
    return 0 unless $ra eq $rb;

    if ($ra eq 'ARRAY') {
        return 0 unless @$a == @$b;
        for my $i (0 .. $#$a) {
            return 0 unless _same_scalar_or_list($a->[$i], $b->[$i]);
        }
        return 1;
    }

    if ($ra eq 'HASH') {
        return 0 unless keys(%$a) == keys(%$b);
        for my $k (keys %$a) {
            return 0 unless exists $b->{$k};
            return 0 unless _same_scalar_or_list($a->{$k}, $b->{$k});
        }
        return 1;
    }

    # Plain scalars.
    return 1 if !defined $a && !defined $b;
    return 0 if !defined $a || !defined $b;
    return $a eq $b ? 1 : 0;
}

sub DESTROY {
    my $self = shift;
    # We intentionally do NOT call unsubscribe from DESTROY: by the
    # time the streamer is destroyed the harness may already be gone
    # (the test command's usual flow is stream -> unsubscribe ->
    # finish -> wait -> DESTROY), and a sync_request against a dead
    # peer risks raising SIGPIPE at the transport layer before
    # returning control. Callers that care should call unsubscribe()
    # explicitly; the harness's peer-delta path reaps stale
    # registrations either way.
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Streamer - Produce a unified event stream from a running harness and/or a log archive.

=head1 SYNOPSIS

    use App::Yath2::Streamer;

    # Live mode: subscribe to a running harness via its IPC handle.
    my $s = App::Yath2::Streamer->new(
        handle => $spawn,
        run    => $run_id,
    );

    # Drain events by callback until the exit_if fires.
    $s->stream(
        callback => sub { my ($event) = @_; print $event->as_json, "\n" },
        exit_if  => sub { $spawn->run_results($run_id)->{state} eq 'complete' },
    );

    # Or iterate directly.
    while (my $event = $s->next) {
        ...
    }

    # Static mode: synthesize events from a completed log directory
    # or a .yath archive file. Archives are extracted to a private
    # tempdir (cleaned up automatically when the Streamer goes away).
    my $s = App::Yath2::Streamer->new(
        log  => "$workdir/logs",
        runs => [$run_id1, $run_id2],
    );

    my $s = App::Yath2::Streamer->new(
        log => '/path/to/20260424-035943.yath',
        run => $run_id,
    );

=head1 DESCRIPTION

A C<Streamer> converts one or more of:

=over 4

=item * an IPC subscription to a running L<Test2::Harness2> service,

=item * a directory of completed log files (with an C<artifacts.json> manifest),

=back

into a stream of L<Test2::Harness2::Event> objects carrying C<harness_run>,
C<harness_job_queued>, C<harness_job_start>, C<harness_job_end>,
C<harness_job_exit>, and C<harness_run_end> facets compatible with the
renderer stack.

The two input modes can coexist for one run: if the caller supplies
both a C<handle> and a C<log>, the handle's IPC messages drive the
event stream and the log directory is treated as a last-resort
fallback for missed artifacts (future).

=head1 EVENT SHAPES

The streamer's synthesized events mirror the facet shapes produced by
the reference/old2 harness so existing renderers keep working:

    facet_data.harness_run            First event per run: run state snapshot.
    facet_data.harness_job_queued     One per job at queue time.
    facet_data.harness_job_start      One per job on launch.
    facet_data.harness_job_end        One per job on completion (pass/fail + file).
    facet_data.harness_job_exit       Paired with harness_job_end; exit + codes.
    facet_data.harness_run_end        Final event per run with aggregate pass/fail.

General events recorded by C<records_general_events> loggers
(currently only L<Test2::Harness2::Collector::Logger::JSONL>) pass
through unchanged.

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

See L<http://dev.perl.org/licenses/>

=cut
