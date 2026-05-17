package App::Yath2::Log::Directory;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use Compress::Zstd ();
use File::Basename qw/dirname/;
use File::Find ();
use File::Path qw/make_path/;
use File::Spec ();
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;

use Test2::Harness2::Util qw/tinysleep/;
use Test2::Harness2::Util::JSONL::Reader;
use Test2::Harness2::LogLayout qw/
    run_dir
    job_dir
    services_global_dir
    service_global_dir
    service_run_dir
    services_run_dir
/;

use App::Yath2::Log::Artifact;
use App::Yath2::Log::Iterator::JSONL;
use App::Yath2::Log::Iterator::Producers;
use App::Yath2::Log::Producer::Run;
use App::Yath2::Log::Producer::Job;
use App::Yath2::Log::Producer::Service;
use App::Yath2::Log::Producer::Collector;
use Cpanel::JSON::XS qw/decode_json/;

use Object::HashBase qw{
    <path
    <live
    +stack
    +seen_starts
    +closed_starts
};

# `with` is safe at the top because every method here is a regular
# `sub name { ... }` declaration -- those BEGIN-elevate, so they exist
# at compile time when the role's `requires` check runs. (The late-with
# workaround is only needed for `*name = sub { ... }` assignments,
# which never BEGIN-elevate.)
use Role::Tiny::With;
with 'App::Yath2::Role::Log';

# Directory-backed Log reader. Implements the full reader API for a
# yath log laid out as a normal filesystem tree. Sealed (post-extract,
# or any case where the log is not actively being written) and live
# (a still-running harness) modes share most of the implementation.
# The live flag changes only iterator behavior:
#
#   - Sealed: an artifact is terminated when its file is fully drained.
#     EOE for the whole log flips true once the iterator stack is
#     empty.
#
#   - Live: an artifact is terminated only when a matching
#     harness_collector_end is observed in the parent's stream
#     (matching collector_pid). EOE for the whole log requires every
#     start to have a matching end AND every reader to have drained.
#
# The depth-first iterator starts at services/harness/events.jsonl(.zst)
# and descends into nested collector logs whenever a
# harness_collector_start facet is surfaced.

sub init {
    my $self = shift;
    croak "'path' is a required attribute"
        unless defined $self->{+PATH} && length $self->{+PATH};
    croak "path '$self->{+PATH}' is not a directory"
        unless -d $self->{+PATH};
    $self->{+LIVE}          //= 0;
    $self->{+SEEN_STARTS}   //= {};
    $self->{+CLOSED_STARTS} //= {};
    return;
}

sub is_live { $_[0]->{+LIVE} ? 1 : 0 }
sub static  { $_[0]->{+LIVE} ? 0 : 1 }

# {{{ Listing methods

sub services {
    my ($self, $run_id) = @_;
    if (defined $run_id) {
        croak "no such run: $run_id" unless $self->has_run($run_id);
        return sort $self->_immediate_dir_children(services_run_dir($run_id));
    }
    return sort $self->_immediate_dir_children(services_global_dir());
}

sub runs {
    my $self = shift;
    my @ids  = $self->_immediate_dir_children('runs');
    return _smart_sort(@ids);
}

sub jobs {
    my ($self, $run_id) = @_;
    croak "run_id is required"   unless defined $run_id;
    croak "no such run: $run_id" unless $self->has_run($run_id);
    my @ids = $self->_immediate_dir_children("runs/$run_id/jobs");
    return _smart_sort(@ids);
}

sub tries {
    my ($self, $run_id, $job_id) = @_;
    croak "run_id is required"           unless defined $run_id;
    croak "job_id is required"           unless defined $job_id;
    croak "no such run: $run_id"         unless $self->has_run($run_id);
    croak "no such job: $run_id/$job_id" unless $self->has_job($run_id, $job_id);
    my @ids = $self->_immediate_dir_children("runs/$run_id/jobs/$job_id");
    return _smart_sort(@ids);
}

# Sort numerically if all entries are pure-digit (the new
# sequential-ord layout); fall back to alphabetic for legacy UUID-style
# layouts. Keeps the API forward-compatible without tripping on
# in-tree harnesses still emitting UUIDs.
sub _smart_sort {
    my @ids = @_;
    return () unless @ids;
    if (!grep { !/^\d+\z/ } @ids) {
        return sort { $a <=> $b } @ids;
    }
    return sort @ids;
}

sub last_try {
    my ($self, $run_id, $job_id) = @_;
    my @t = $self->tries($run_id, $job_id);
    return undef unless @t;
    return $t[-1];
}

sub has_service {
    my ($self, $name, $run_id) = @_;
    croak "service name is required" unless defined $name && length $name;
    if (defined $run_id) {
        return 0 unless $self->has_run($run_id);
        return -d File::Spec->catdir($self->{+PATH}, service_run_dir($run_id, $name)) ? 1 : 0;
    }
    return -d File::Spec->catdir($self->{+PATH}, service_global_dir($name)) ? 1 : 0;
}

sub has_run {
    my ($self, $run_id) = @_;
    return 0 unless defined $run_id && length $run_id;
    return 0 if $run_id =~ m{/};
    return -d File::Spec->catdir($self->{+PATH}, run_dir($run_id)) ? 1 : 0;
}

sub has_job {
    my ($self, $run_id, $job_id) = @_;
    return 0 unless $self->has_run($run_id);
    return 0 unless defined $job_id && length $job_id;
    return 0 if $job_id =~ m{/};
    return -d File::Spec->catdir($self->{+PATH}, "runs/$run_id/jobs/$job_id") ? 1 : 0;
}

sub has_try {
    my ($self, $run_id, $job_id, $job_try) = @_;
    return 0 unless $self->has_job($run_id, $job_id);
    return 0 unless defined $job_try && length $job_try;
    return 0 if $job_try =~ m{/};
    return -d File::Spec->catdir($self->{+PATH}, "runs/$run_id/jobs/$job_id/$job_try") ? 1 : 0;
}

# Names of immediate child directories of $rel. Returns a list (not
# sorted -- callers sort).
sub _immediate_dir_children {
    my ($self, $rel) = @_;
    my $dir = File::Spec->catdir($self->{+PATH}, $rel);
    return () unless -d $dir;
    opendir(my $dh, $dir) or return ();
    my @names;
    while (defined(my $entry = readdir($dh))) {
        next if $entry eq '.' || $entry eq '..';
        my $abs = File::Spec->catdir($dir, $entry);
        push @names => $entry if -d $abs;
    }
    closedir($dh);
    return @names;
}

sub _numeric_immediate_children {
    my ($self, $rel) = @_;
    return grep { /^\d+\z/ } $self->_immediate_dir_children($rel);
}

# }}}

# {{{ Producer iterators

sub run_producers {
    my $self = shift;
    my @ids  = $self->runs;
    my $i    = 0;
    return App::Yath2::Log::Iterator::Producers->new(
        next_cb => sub {
            return undef if $i >= @ids;
            my $id = $ids[$i++];
            return $self->_build_run_producer($id);
        },
    );
}

sub job_producers {
    my ($self, $run_id) = @_;
    croak("run_id is required") unless defined $run_id;
    my @pairs;
    for my $jid ($self->jobs($run_id)) {
        for my $try ($self->tries($run_id, $jid)) {
            push @pairs, [$jid, $try];
        }
    }
    my $i = 0;
    return App::Yath2::Log::Iterator::Producers->new(
        next_cb => sub {
            return undef if $i >= @pairs;
            my ($jid, $try) = @{$pairs[$i++]};
            return $self->_build_job_producer($run_id, $jid, $try);
        },
    );
}

sub service_producers {
    my ($self, $run_id) = @_;
    my @ids = $self->services($run_id);
    my $i   = 0;
    return App::Yath2::Log::Iterator::Producers->new(
        next_cb => sub {
            return undef if $i >= @ids;
            my $sid = $ids[$i++];
            return $self->_build_service_producer($sid, $run_id);
        },
    );
}

sub collector_producers {
    my $self = shift;
    my @ids  = $self->_immediate_dir_children('collectors');
    my $i    = 0;
    return App::Yath2::Log::Iterator::Producers->new(
        next_cb => sub {
            return undef if $i >= @ids;
            my $cid = $ids[$i++];
            return $self->_build_collector_producer($cid);
        },
    );
}

sub _build_run_producer {
    my ($self, $id) = @_;
    my $sealed = $self->_read_sealed("runs/$id/.sealed");
    return App::Yath2::Log::Producer::Run->new(
        id            => $id,
        kind          => 'run',
        parent_id     => undef,
        run_id        => $id,
        state         => ($sealed ? 'sealed' : ($self->is_live ? 'partial' : 'sealed')),
        started_at    => $sealed ? $sealed->{started_at} : undef,
        ended_at      => $sealed ? $sealed->{sealed_at}  : undef,
        pass          => $sealed ? $sealed->{pass}       : undef,
        exit          => $sealed ? $sealed->{exit}       : undef,
        log           => $self,
        artifact_refs => $self->_run_artifact_refs($id),
    );
}

sub _build_job_producer {
    my ($self, $run_id, $jid, $try) = @_;
    my $base   = "runs/$run_id/jobs/$jid/$try";
    my $sealed = $self->_read_sealed("$base/.sealed");
    my $refs   = $self->_job_artifact_refs($run_id, $jid, $try);
    return App::Yath2::Log::Producer::Job->new(
        id               => $jid,
        kind             => 'job',
        parent_id        => $run_id,
        run_id           => $run_id,
        try              => $try,
        state            => ($sealed ? 'sealed' : ($self->is_live ? 'partial' : 'sealed')),
        started_at       => $sealed ? $sealed->{started_at} : undef,
        ended_at         => $sealed ? $sealed->{sealed_at}  : undef,
        pass             => $sealed ? $sealed->{pass}       : undef,
        report_available => (exists $refs->{report} ? 1 : 0),
        log              => $self,
        artifact_refs    => $refs,
    );
}

sub _build_service_producer {
    my ($self, $sid, $run_id) = @_;
    my $base   = defined $run_id ? "runs/$run_id/services/$sid" : "services/$sid";
    my $sealed = $self->_read_sealed("$base/.sealed");
    return App::Yath2::Log::Producer::Service->new(
        id            => $sid,
        kind          => 'service',
        parent_id     => $run_id,
        run_id        => $run_id,
        state         => ($sealed ? 'sealed' : ($self->is_live ? 'partial' : 'sealed')),
        started_at    => $sealed ? $sealed->{started_at} : undef,
        ended_at      => $sealed ? $sealed->{sealed_at}  : undef,
        log           => $self,
        artifact_refs => $self->_service_artifact_refs($sid, $run_id),
    );
}

sub _build_collector_producer {
    my ($self, $cid) = @_;
    my $sealed = $self->_read_sealed("collectors/$cid/.sealed");
    return App::Yath2::Log::Producer::Collector->new(
        id            => $cid,
        kind          => 'collector',
        parent_id     => undef,
        run_id        => undef,
        state         => ($sealed ? 'sealed' : ($self->is_live ? 'partial' : 'sealed')),
        started_at    => $sealed ? $sealed->{started_at} : undef,
        ended_at      => $sealed ? $sealed->{sealed_at}  : undef,
        log           => $self,
        artifact_refs => {},
    );
}

sub _read_sealed {
    my ($self, $rel) = @_;
    my $abs = File::Spec->catfile($self->{+PATH}, $rel);
    return undef unless -e $abs;
    open(my $fh, '<', $abs) or return undef;
    my $line = <$fh>;
    close($fh);
    return undef unless defined $line && length $line;
    my $ok = eval { $line = decode_json($line); 1 };

    unless ($ok) {
        warn "Failed to decode .sealed marker '$rel': $@";
        return undef;
    }
    return undef unless ref $line eq 'HASH';
    return $line;
}

sub _run_artifact_refs {
    my ($self, $id) = @_;
    my $base = "runs/$id";
    my %refs;
    for my $kind (qw/spec report events/) {
        my $rel = $self->_first_existing("$base/$kind.jsonl", "$base/$kind.jsonl.zst");
        $refs{$kind} = $rel if defined $rel;
    }
    return \%refs;
}

sub _job_artifact_refs {
    my ($self, $run_id, $jid, $try) = @_;
    my $base = "runs/$run_id/jobs/$jid/$try";
    my %refs;
    for my $kind (qw/spec report events stdout stderr/) {
        my $rel = $self->_first_existing("$base/$kind.jsonl", "$base/$kind.jsonl.zst");
        $refs{$kind} = $rel if defined $rel;
    }
    return \%refs;
}

# Extended in Stage 2 to return real artifact refs for services.
sub _service_artifact_refs { return {} }

sub _first_existing {
    my ($self, @rels) = @_;
    for my $rel (@rels) {
        my $abs = File::Spec->catfile($self->{+PATH}, $rel);
        return $rel if -e $abs;
    }
    return undef;
}

# }}}

# {{{ Artifacts handle

# artifacts(@positional)
# artifacts({...})  -- hashref form
#
# Forms:
#
#   artifacts()                            -> archive root (for save/get)
#   artifacts($service_name)               -> global service
#   artifacts($run_id)                     -> run itself
#   artifacts($run_id, $service_name)      -> run-scoped service
#   artifacts($run_id, $job_id)            -> highest try of job
#   artifacts($run_id, $job_id, $job_try)  -> specific try
#   artifacts({service => ..., run_id => ..., job_id => ..., job_try => ...})
#
# Service names cannot start with a digit, so a pure-digit first
# positional unambiguously means run id.
sub artifacts {
    my $self = shift;

    return $self->_artifacts_from_args(@_) if @_ == 1 && ref($_[0]) eq 'HASH';
    return $self->_artifacts_root unless @_;

    my @args = @_;

    if (@args == 1) {
        my $arg = $args[0];
        # Disambiguate: pure-digit -> run id (service names cannot start
        # with a digit). For non-digit arguments, treat as service if a
        # global service of that name exists; otherwise as run_id
        # (current writers may use UUIDs as run_ids during the transition
        # to ord ints).
        if (defined $arg && $arg =~ /^\d+\z/) {
            return $self->_artifacts_from_args({run_id => $arg});
        }
        if (defined $arg && $self->has_service($arg)) {
            return $self->_artifacts_from_args({service => $arg});
        }
        # Fallback: treat as run_id; throws if neither service nor run.
        return $self->_artifacts_from_args({run_id => $arg});
    }

    if (@args == 2) {
        my ($run_id, $second) = @args;
        # Service names cannot start with a digit, so a numeric second
        # arg always means job_id; otherwise service.
        if (defined $second && $second =~ /^\d+\z/) {
            return $self->_artifacts_from_args({run_id => $run_id, job_id => $second});
        }
        return $self->_artifacts_from_args({run_id => $run_id, service => $second});
    }

    if (@args == 3) {
        my ($run_id, $job_id, $job_try) = @args;
        return $self->_artifacts_from_args({
            run_id  => $run_id,
            job_id  => $job_id,
            job_try => $job_try,
        });
    }

    croak "artifacts() got too many positional arguments";
}

sub _artifacts_root {
    my $self = shift;
    return App::Yath2::Log::Artifact->new(
        log  => $self,
        root => $self->{+PATH},
        base => undef,
        live => $self->{+LIVE},
    );
}

sub _artifacts_from_args {
    my ($self, $args) = @_;
    my $service = $args->{service};
    my $run_id  = $args->{run_id};
    my $job_id  = $args->{job_id};
    my $job_try = $args->{job_try};

    croak "service name cannot start with a digit"
        if defined $service && $service =~ /^\d/;

    if (defined $service) {
        if (defined $run_id) {
            croak "no such run: $run_id" unless $self->has_run($run_id);
            croak "no such service: $service in run $run_id"
                unless $self->has_service($service, $run_id);
            return $self->_make_artifact(service_run_dir($run_id, $service));
        }
        croak "no such service: $service"
            unless $self->has_service($service);
        return $self->_make_artifact(service_global_dir($service));
    }

    if (defined $job_id) {
        croak "run_id is required when job_id is given"
            unless defined $run_id;
        croak "no such run: $run_id"         unless $self->has_run($run_id);
        croak "no such job: $run_id/$job_id" unless $self->has_job($run_id, $job_id);

        if (!defined $job_try) {
            my $lt = $self->last_try($run_id, $job_id);
            croak "no tries for job $run_id/$job_id"
                unless defined $lt;
            $job_try = $lt;
        }
        croak "no such try: $run_id/$job_id/$job_try"
            unless $self->has_try($run_id, $job_id, $job_try);

        return $self->_make_artifact(job_dir($run_id, $job_id, $job_try));
    }

    if (defined $run_id) {
        croak "no such run: $run_id" unless $self->has_run($run_id);
        return $self->_make_artifact(run_dir($run_id));
    }

    return $self->_artifacts_root;
}

sub _make_artifact {
    my ($self, $base) = @_;
    return App::Yath2::Log::Artifact->new(
        log  => $self,
        root => $self->{+PATH},
        base => $base,
        live => $self->{+LIVE},
    );
}

# }}}

# {{{ Iterator (depth-first walk)

# Lazily build the iterator stack: starts with the harness service's
# events.jsonl.zst on top.
sub _stack {
    my $self = shift;
    return $self->{+STACK} //= [
        $self->_open_artifact_reader(
            base          => 'services/harness',
            run_id        => undef,
            job_id        => undef,
            job_try       => undef,
            service       => 'harness',
            collector_pid => undef,
        ),
    ];
}

# Open a reader for an artifact's events.jsonl(.zst). Returns an
# entry: { reader, base, ident{run_id,job_id,job_try,service},
# collector_pid, eof_logical }. ident is what gets injected into
# events surfaced from this reader.
sub _open_artifact_reader {
    my ($self, %args) = @_;

    my $base    = $args{base};
    my $abs_zst = File::Spec->catfile($self->{+PATH}, $base, 'events.jsonl.zst');
    my $abs     = File::Spec->catfile($self->{+PATH}, $base, 'events.jsonl');

    my $path;
    if (-e $abs_zst) {
        $path = $abs_zst;
    }
    elsif (-e $abs) {
        $path = $abs;
    }
    else {
        # Reader will return undef on read; that's fine. Pick the
        # zst path optimistically so a writer that creates it
        # mid-iteration is observed.
        $path = $abs_zst;
    }

    return {
        reader => Test2::Harness2::Util::JSONL::Reader->new(path => $path),
        base   => $base,
        ident  => {
            (defined $args{run_id}  ? (run_id       => $args{run_id})  : ()),
            (defined $args{job_id}  ? (job_id       => $args{job_id})  : ()),
            (defined $args{job_try} ? (job_try      => $args{job_try}) : ()),
            (defined $args{service} ? (service_name => $args{service}) : ()),
        },
        collector_pid => $args{collector_pid},
    };
}

# Inject path-aware identifiers into an event hash. Mutates the event
# in place and returns it.
sub _inject_identifiers {
    my ($self, $event, $ident) = @_;
    return $event unless ref($event) eq 'HASH';

    my $fd = $event->{facet_data} // do { $event->{facet_data} = {}; $event->{facet_data} };
    my $h  = $fd->{harness}       // do { $fd->{harness}       = {}; $fd->{harness} };

    for my $k (qw/run_id job_id job_try service_name/) {
        next unless exists $ident->{$k};
        $h->{$k} //= $ident->{$k};
    }

    return $event;
}

# Detect a harness_collector_start facet on an event. Returns the
# facet content hash or undef.
sub _facet {
    my ($self, $event, $name) = @_;
    return undef unless ref($event) eq 'HASH';
    my $fd = $event->{facet_data};
    return undef unless ref($fd) eq 'HASH';
    return $fd->{$name};
}

# Compute the on-disk base dir for a harness_collector_start facet.
# Returns the relative path (e.g. 'runs/0/jobs/2/0') or undef when
# the content is malformed / unsupported.
sub _base_for_collector_start {
    my ($self, $content) = @_;
    return undef unless ref($content) eq 'HASH';

    my $type = $content->{type};
    return undef unless defined $type;

    if ($type eq 'Job') {
        my $rid = $content->{run_id};
        my $jid = $content->{id};
        my $try = $content->{job_try} // 0;
        return undef unless defined $rid && defined $jid;
        return "runs/$rid/jobs/$jid/$try";
    }

    if ($type eq 'Run') {
        my $rid = $content->{id};
        return undef unless defined $rid;
        return "runs/$rid";
    }

    if ($type eq 'Service') {
        my $name = $content->{service_name} // $content->{id};
        return undef unless defined $name && length $name;
        my $rid = $content->{run_id};
        return defined $rid ? "runs/$rid/services/$name" : "services/$name";
    }

    return undef;
}

# Pull one record from the iterator. Depth-first: try the top of
# stack first; on EOF/live-wait at top, walk down to older readers
# so the parent can produce a harness_collector_end that closes the
# child. Mutates state by pushing on collector_start and marking
# CLOSED_STARTS on collector_end.
sub event {
    my ($self, $timeout) = @_;

    my $stack    = $self->_stack;
    my $deadline = (defined $timeout && $timeout > 0) ? time + $timeout : undef;

    while (1) {
        last unless @$stack;

        my ($got, $owner) = $self->_read_next_from_stack($stack);

        if (defined $got) {
            return $self->_process_event($got, $owner, $stack);
        }

        # No reader produced a record. Pop top entries that are now
        # done; then either bail (sealed, or live without a deadline)
        # or poll for a beat.
        my $popped = 0;
        while (@$stack && $self->_top_is_done($stack->[-1])) {
            pop @$stack;
            $popped++;
        }

        unless (@$stack) {
            last;
        }

        # If we popped at least one entry the older reader may now
        # be the top -- loop and try reading again before sleeping.
        next if $popped;

        unless ($self->{+LIVE}) {
            # Sealed: any non-empty stack here means the file is
            # finished but we never saw a close. The caller will
            # see EOE flip true on the next call (we let the stack
            # naturally drain on subsequent iterations).
            last;
        }

        return undef unless defined $deadline;
        last if time >= $deadline;
        tinysleep(0.05);
    }

    return undef;
}

# Try to read one record from the iterator stack. Walks from top down
# so a parent harness_collector_end can close a child whose reader is
# exhausted but still on the stack. Returns (record, owner_entry) or
# an empty list when no reader has a record available.
sub _read_next_from_stack {
    my ($self, $stack) = @_;

    for (my $i = $#$stack; $i >= 0; $i--) {
        my $entry = $stack->[$i];
        my $item;
        if ($entry->{peeked} && @{$entry->{peeked}}) {
            $item = shift @{$entry->{peeked}};
        }
        else {
            $item = $entry->{reader}->readline;
        }
        if (defined $item) {
            return ($item, $entry);
        }
    }
    return ();
}

# Process one freshly-read event: track collector_start / _end
# bookkeeping (and push a nested reader on _start) and return the
# event with owner identifiers injected.
sub _process_event {
    my ($self, $got, $owner, $stack) = @_;

    if (my $start = $self->_facet($got, 'harness_collector_start')) {
        my $cpid = $start->{collector_pid};
        $self->{+SEEN_STARTS}->{$cpid} = $start if defined $cpid;
        my $child_base = $self->_base_for_collector_start($start);
        if (defined $child_base) {
            push @$stack => $self->_open_artifact_reader(
                $self->_child_reader_args($start, $cpid, $child_base),
            );
        }
        return $self->_inject_identifiers($got, $owner->{ident});
    }

    if (my $end = $self->_facet($got, 'harness_collector_end')) {
        my $cpid = $end->{collector_pid};
        $self->{+CLOSED_STARTS}->{$cpid} = 1 if defined $cpid;
        return $self->_inject_identifiers($got, $owner->{ident});
    }

    return $self->_inject_identifiers($got, $owner->{ident});
}

# Build the keyword arglist for _open_artifact_reader from a
# harness_collector_start payload. Routes Job / Run / Service types
# to their respective identifier shapes.
sub _child_reader_args {
    my ($self, $start, $cpid, $child_base) = @_;

    my %args = (base => $child_base, collector_pid => $cpid);
    my $type = $start->{type};
    if ($type eq 'Job') {
        $args{run_id}  = $start->{run_id};
        $args{job_id}  = $start->{id};
        $args{job_try} = $start->{job_try} // 0;
    }
    elsif ($type eq 'Run') {
        $args{run_id} = $start->{id};
    }
    elsif ($type eq 'Service') {
        $args{service} = $start->{service_name} // $start->{id};
        $args{run_id}  = $start->{run_id} if defined $start->{run_id};
    }
    return %args;
}

# Top-of-stack reader: is it closed (sealed: always once drained;
# live: matching collector_end seen or LIVE absent for the harness
# root)? Called only when the outer loop has confirmed no record
# is currently available from this reader.
sub _top_drainable_done {
    my ($self, $top) = @_;
    return $self->_top_is_done($top);
}

# Has the top reader hit a final end-of-stream? Sealed: empty file
# means done. Live: only done when the matching harness_collector_end
# has been observed.
sub _top_is_done {
    my ($self, $top) = @_;

    return 1 unless $self->{+LIVE};

    my $cpid = $top->{collector_pid};

    # The harness root has no collector_pid -- in live mode it stays
    # alive until the directory disappears, which is outside our
    # purview. We treat the harness as "done" only when the LIVE
    # marker file is absent (best effort).
    if (!defined $cpid) {
        return 1 unless $self->_live_marker_present;
        return 0;
    }

    return 1 if $self->{+CLOSED_STARTS}->{$cpid};

    # The parent is supposed to emit a synthetic harness_collector_end
    # on a peer-gone. Until that machinery is universal, accept
    # "LIVE marker absent" as the last-resort liveness signal: once
    # the harness collector has shut down (and taken LIVE with it),
    # nothing new will append to any nested events.jsonl.zst, so any
    # SEEN_STARTS without a matching end is effectively closed.
    return 1 unless $self->_live_marker_present;

    return 0;
}

sub _live_marker_present {
    my $self = shift;
    my $live = File::Spec->catfile($self->{+PATH}, 'LIVE');
    return -e $live ? 1 : 0;
}

# events($timeout) -- list-context iterator. Empty list = paused; a
# list ending with undef = terminated.
sub events {
    my ($self, $timeout) = @_;
    my @out;
    while (1) {
        my $e = $self->event(0);
        last unless defined $e;
        push @out => $e;
    }
    if (!@out && $self->EOE) {
        return (undef);
    }
    return @out;
}

sub EOE { $_[0]->end_of_events }

sub end_of_events {
    my $self  = shift;
    my $stack = $self->_stack;

    # Pop any top-of-stack readers that are now done and have nothing
    # buffered. This lets EOE notice when the log has fully drained
    # without requiring an extra event() call from the caller.
    while (@$stack) {
        my $top = $stack->[-1];
        # If the top reader still has data, we are not done.
        my $item = $top->{reader}->readline;
        if (defined $item) {
            # Put it back: re-prepend by rebuilding the buffer. The
            # readline interface drains one record into the buffer,
            # so push it onto a private "peeked" slot and serve it on
            # the next event() call.
            push @{$top->{peeked}} => $item;
            return 0;
        }
        last unless $self->_top_is_done($top);
        pop @$stack;
    }

    return 0 if @$stack;
    return 1 unless $self->{+LIVE};

    # Live: stack drained. Normally we wait until all known starts
    # have matching ends; if the LIVE sentinel is gone the harness
    # has shut down and nothing more will append, so any unclosed
    # start is treated as closed (matches the LIVE-marker fallback in
    # _top_is_done).
    if ($self->_live_marker_present) {
        for my $cpid (keys %{$self->{+SEEN_STARTS}}) {
            return 0 unless $self->{+CLOSED_STARTS}->{$cpid};
        }
    }

    return 1;
}

sub reset {
    my $self = shift;
    if (my $stack = delete $self->{+STACK}) {
        for my $entry (@$stack) {
            eval { $entry->{reader}->close; 1 };
        }
    }
    $self->{+SEEN_STARTS}   = {};
    $self->{+CLOSED_STARTS} = {};
    return;
}

# }}}

# {{{ archive / extract

# extract($dir, %opts).
#
# Walks every file in the source tree and copies it to $dir. With
# 'compressed => 0' (the default) zstd-suffixed source files are
# decompressed and the suffix is stripped on the way out. With
# 'compressed => 1' files are copied verbatim.
#
# Filter options:
#   runs         => [ord, ord, ...]   only include these runs (globals always)
#   exclude_runs => [ord, ...]        include all runs except these
#
# Mutually exclusive.
sub extract {
    my ($self, $dir, %opts) = @_;
    croak "destination is required" unless defined $dir && length $dir;

    croak "destination '$dir' already exists and is non-empty"
        if -e $dir && -d $dir && _dir_non_empty($dir);

    my $compressed = exists $opts{compressed} ? $opts{compressed} : 0;
    my ($runs, $exclude_runs) = $self->_normalize_run_filters(\%opts);

    make_path($dir);

    require Test2::Harness2::Util::Zstd;

    for my $rel ($self->_list_files) {
        next unless $self->_run_filter_includes($rel, $runs, $exclude_runs);

        my $src    = File::Spec->catfile($self->{+PATH}, $rel);
        my $is_zst = $rel =~ /\.zst\z/ ? 1 : 0;

        my $out_rel = $rel;
        if (!$compressed && $is_zst) {
            $out_rel =~ s/\.zst\z//;
        }

        # Skip the LIVE sentinel in extract.
        next if $rel eq 'LIVE';

        my $out_abs = File::Spec->catfile($dir, $out_rel);
        my $par     = _parent_dir($out_abs);
        make_path($par) unless -d $par;

        open(my $in, '<', $src) or croak "open '$src': $!";
        binmode $in;
        my $bytes = do { local $/; <$in> };
        close $in;

        if (!$compressed && $is_zst) {
            $bytes = Test2::Harness2::Util::Zstd::decompress_blob($bytes);
        }

        open(my $out, '>', $out_abs) or croak "open '$out_abs': $!";
        binmode $out;
        print $out $bytes;
        close $out or croak "close '$out_abs': $!";
    }

    require App::Yath2::Log::Directory;
    return App::Yath2::Log::Directory->new(path => $dir, live => 0);
}

sub archive {
    my ($self, $out, %opts) = @_;
    croak "output path is required" unless defined $out && length $out;

    my $format = $opts{format} // 'tar.zidx';
    $format = 'tar.zidx' if $format eq 'tar';

    my ($runs, $exclude_runs) = $self->_normalize_run_filters(\%opts);

    # Default: zstd-compress every artifact body. Pass compress=0 to
    # store plaintext (greppable; bigger). The plaintext path
    # decompresses any source .jsonl.zst on the way out.
    my $compress = exists $opts{compress} ? ($opts{compress} ? 1 : 0) : 1;

    if ($format eq 'sqlite') {
        require App::Yath2::DB;
        # Refuse to clobber an existing destination -- fresh file only.
        croak "destination '$out' already exists" if -e $out;
        my $dest = App::Yath2::DB->new(file => $out);
        # DB::insert builds the archive metadata and drops a fresh
        # meta.json into the archive root itself. seal => 1 appends
        # the YATHFOOT trailer (and a zstd-compressed copy of
        # meta.json) past the SQLite body so external tools can read
        # meta.json without a SQLite parser.
        $dest->insert(
            $self,
            runs         => $runs,
            exclude_runs => $exclude_runs,
            compress     => $compress,
            seal         => 1,
        );
        return $dest;
    }

    if ($format ne 'tar.zidx') {
        croak "unknown archive format: $format";
    }

    # Build a fresh meta.json for the tar.zidx archive root. tar.zidx
    # sealing is one-shot (no insert step); we plumb the bytes into
    # the writer's extra_files option.
    require App::Yath2::Log;
    my $meta       = App::Yath2::Log->build_archive_meta;
    my $meta_bytes = App::Yath2::Log->encode_archive_meta($meta);

    require App::Yath2::Log::TarZIdx;
    my $arc = App::Yath2::Log::TarZIdx->new(path => $out);

    if ($arc->can('_write_from_directory')) {
        $arc->_write_from_directory(
            $self->{+PATH},
            runs            => $runs,
            exclude_runs    => $exclude_runs,
            extra_files     => {App::Yath2::Log->META_FILENAME() => $meta_bytes},
            meta_json_bytes => $meta_bytes,
            compress        => $compress,
        );
        return $arc;
    }

    croak "TarZIdx archive writer not yet implemented";
}

sub _normalize_run_filters {
    my ($self, $opts) = @_;
    my $runs         = $opts->{runs};
    my $exclude_runs = $opts->{exclude_runs};
    croak "'runs' and 'exclude_runs' are mutually exclusive"
        if defined $runs && defined $exclude_runs;
    return ($runs, $exclude_runs);
}

# Return true if $rel should be included given the run filters. Files
# under runs/$N/ are filtered; everything else (globals) is included.
sub _run_filter_includes {
    my ($self, $rel, $runs, $exclude_runs) = @_;

    return 1 unless $rel =~ m{^runs/(\d+)/};
    my $rid = $1;

    if (defined $runs) {
        return scalar grep { $_ eq $rid } @$runs;
    }

    if (defined $exclude_runs) {
        return scalar(grep { $_ eq $rid } @$exclude_runs) ? 0 : 1;
    }

    return 1;
}

sub _list_files {
    my $self = shift;
    my @files;
    my $root = $self->{+PATH};
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                return unless -f $_;
                my $rel = File::Spec->abs2rel($_, $root);
                $rel =~ s{\\}{/}g;
                push @files => $rel;
            },
        },
        $root,
    );
    return @files;
}

sub list_files { $_[0]->_list_files }

sub list_dirs {
    my $self = shift;
    my @dirs;
    my $root = $self->{+PATH};
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                return unless -d $_;
                return if $_ eq $root;
                my $rel = File::Spec->abs2rel($_, $root);
                $rel =~ s{\\}{/}g;
                push @dirs => $rel;
            },
        },
        $root,
    );
    return @dirs;
}

sub has_file {
    my ($self, $rel) = @_;
    return -f File::Spec->catfile($self->{+PATH}, $rel) ? 1 : 0;
}

sub read_file {
    my ($self, $rel) = @_;
    my $abs = File::Spec->catfile($self->{+PATH}, $rel);
    open(my $fh, '<', $abs) or croak "read_file '$rel': $!";
    binmode $fh;
    return $fh;
}

sub absolute_path {
    my ($self, $rel) = @_;
    return File::Spec->catfile($self->{+PATH}, $rel);
}

# }}}

# {{{ Artifact backend primitives
#
# Used by App::Yath2::Log::Artifact to read / list / save artifacts.
# Directory uses straightforward filesystem operations for these.

# Open a reader for the artifact at the relative path $ref. Used by
# the role-level artifact_for_producer to serve producer descriptors.
# Returns a Test2::Harness2::Util::JSONL::Reader so JSONL artifacts
# are decoded automatically; returns undef when the path does not
# exist on disk (caller already checked that $ref is defined).
sub _open_artifact_reader_for_relpath {
    my ($self, $relpath) = @_;
    my $abs = File::Spec->catfile($self->{+PATH}, $relpath);
    return undef unless -e $abs;
    return Test2::Harness2::Util::JSONL::Reader->new(path => $abs);
}

sub _open_artifact_for_producer {
    my ($self, $producer, $kind, $ref) = @_;
    return $self->_open_artifact_reader_for_relpath($ref);
}

# Returns ($exists, $is_zst). $exists is a boolean; $is_zst is true
# when the artifact path ends in .zst (caller may also pass a path
# without the suffix and let the caller probe both forms).
sub _artifact_exists {
    my ($self, $rel) = @_;
    my $abs = File::Spec->catfile($self->{+PATH}, $rel);
    return (0, 0) unless -e $abs;
    my $is_zst = $rel =~ /\.zst\z/ ? 1 : 0;
    return (1, $is_zst);
}

# Read the raw bytes of $rel (no decompression). Compressed files
# come back as compressed bytes; the caller decides whether to
# decompress.
sub _artifact_read {
    my ($self, $rel) = @_;
    my $abs = File::Spec->catfile($self->{+PATH}, $rel);
    open(my $fh, '<', $abs) or croak "open '$abs': $!";
    binmode $fh;
    local $/;
    my $bytes = <$fh>;
    close $fh;
    return $bytes;
}

# Open a filehandle for $rel.
sub _artifact_open_fh {
    my ($self, $rel) = @_;
    my $abs = File::Spec->catfile($self->{+PATH}, $rel);
    open(my $fh, '<', $abs) or croak "open '$abs': $!";
    binmode $fh;
    return $fh;
}

# Decompress a possibly-multi-frame zstd byte string. Single-file
# .json.zst snapshots are one frame; .jsonl.zst event streams
# concatenate one self-contained zstd frame per record.
sub _decompress_jsonl_bytes {
    my ($self, $bytes) = @_;
    require Test2::Harness2::Util::Zstd;

    # Use the streaming reader-based path: write to a temp scalar fh
    # and decode frame-by-frame.
    my $out    = '';
    my $offset = 0;
    while ($offset < length $bytes) {
        my $size = Test2::Harness2::Util::Zstd::zstd_frame_size(substr($bytes, $offset));
        croak "incomplete zstd frame in jsonl bytes" unless defined $size;
        my $frame = substr($bytes, $offset, $size);
        $offset += $size;
        my $plain = Compress::Zstd::decompress($frame);
        croak "zstd decompress failed in jsonl bytes" unless defined $plain;
        $out .= $plain;
    }
    return $out;
}

# Records-backed iterator? Directory always returns undef -- it
# always uses a file-backed iterator (live-aware).
sub _artifact_iter_records { return undef }

# Sorted basenames of $rel (a directory). Returns () when missing.
sub _artifact_list_dir {
    my ($self, $rel) = @_;
    my $dir = File::Spec->catdir($self->{+PATH}, $rel);
    return () unless -d $dir;
    opendir(my $dh, $dir) or return ();
    my @names;
    while (defined(my $entry = readdir($dh))) {
        next if $entry eq '.' || $entry eq '..';
        next unless -f File::Spec->catfile($dir, $entry);
        push @names => $entry;
    }
    closedir($dh);
    return sort @names;
}

# Atomically write artifact bytes. Required positional/named args:
#   rel                final relative path (with or without .zst)
#   rel_alt            stale plaintext counterpart to clean up
#   rel_alt_zst        stale compressed counterpart to clean up
#   bytes              raw plaintext bytes (will be compressed if requested)
#   compress           boolean; whether to compress on write
#   force_no_overwrite boolean
sub _artifact_save {
    my ($self, %p) = @_;
    require Test2::Harness2::Util::Zstd;

    my $rel = $p{rel};
    my $abs = File::Spec->catfile($self->{+PATH}, $rel);

    if ($p{force_no_overwrite}) {
        croak "file already exists: $abs"
            if -e $abs
            || -e File::Spec->catfile($self->{+PATH}, "$rel.zst");
    }

    my $par = dirname($abs);
    make_path($par) unless -d $par;

    my $payload =
        $p{compress}
        ? Test2::Harness2::Util::Zstd::compress_blob($p{bytes})
        : $p{bytes};

    require Test2::Harness2::Util;
    Test2::Harness2::Util::write_file_atomic($abs, $payload);

    # Drop the stale alternate form so future reads pick up only the
    # form the caller asked for.
    my $other =
        $p{compress}
        ? File::Spec->catfile($self->{+PATH}, $p{rel_alt})
        : File::Spec->catfile($self->{+PATH}, $p{rel_alt_zst});
    unlink $other if $other ne $abs && -e $other;

    return $abs;
}

# }}}

sub _parent_dir {
    my ($path) = @_;
    require File::Basename;
    return File::Basename::dirname($path);
}

sub _dir_non_empty {
    my ($dir) = @_;
    opendir(my $dh, $dir) or return 0;
    while (defined(my $entry = readdir($dh))) {
        next if $entry eq '.' || $entry eq '..';
        closedir($dh);
        return 1;
    }
    closedir($dh);
    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Log::Directory - Directory-backed Log reader.

=head1 DESCRIPTION

Reads a yath log laid out as a normal filesystem directory. Used for
both sealed (post-extract / not-running) and live (still-being-written)
trees -- the C<live> attribute toggles iterator behavior.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=cut
