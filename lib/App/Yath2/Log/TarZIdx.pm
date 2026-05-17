package App::Yath2::Log::TarZIdx;
use strict;
use warnings;

# The 32-byte zidx footer and the YATHFOOT trailer use pack Q< (unsigned
# 64-bit little-endian); requires perl built with 64-bit native int.
use Config ();

BEGIN {
    die "App::Yath2::Log::TarZIdx requires perl with 64-bit native int " . "(\$Config{ivsize} >= 8); this perl reports ivsize=$Config::Config{ivsize}.\n"
        if $Config::Config{ivsize} < 8;
}

our $VERSION = '2.000013';

use Carp qw/croak/;
use Compress::Zstd ();
use Fcntl qw/SEEK_END SEEK_SET/;
use File::Basename qw/dirname/;
use File::Find ();
use File::Path qw/make_path/;
use File::Spec ();

use Test2::Harness2::Util::JSON qw/decode_json encode_json/;
use Test2::Harness2::Util::Zstd qw/zstd_frame_size/;
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

use Object::HashBase qw/path +_index +_seen_starts +_closed_starts +_walk/;

# `with` is safe at the top because every method here is a regular
# `sub name { ... }` declaration -- those BEGIN-elevate, so they exist
# at compile time when the role's `requires` check runs. (The late-with
# workaround is only needed for `*name = sub { ... }` assignments,
# which never BEGIN-elevate.)
use Role::Tiny::With;
with 'App::Yath2::Role::Log';

# tar.zidx is the single archive format yath produces. Layout:
# a USTAR-format tar with per-entry payloads (each individually
# zstd-compressed when the source was plaintext, or stored verbatim
# when the source was already a .zst-suffixed file), plus a special
# index entry, plus a 32-byte footer pointing at the index.
#
# This backend implements the full reader API (services/runs/jobs/
# tries/artifacts/event/EOE) directly against the tar -- no
# extract-to-tempdir step is required. Random access into the tar
# uses the index, so reading any single artifact does not require
# decompressing the entire archive.

use constant BLOCK_SIZE          => 512;
use constant INDEX_ENTRY_NAME    => '__index__.json.zst';
use constant TAR_ZIDX_MAGIC      => "YZIDXv1\0";
use constant TAR_ZIDX_FOOTER_LEN => 32;

sub is_live { 0 }
sub static  { 1 }

sub absolute_path {
    my ($self, $rel) = @_;
    croak "absolute_path is unavailable for the tar.zidx backend; " . "extract first or read via the Log API ($rel)";
}

# {{{ Format helpers (methods so subclasses / future formats can override)

sub pack_ustar_header {
    my ($self, $name, $size, %opts) = @_;
    my $typeflag = $opts{typeflag} // '0';
    my $mode     = $opts{mode}     // oct('0644');

    my ($base, $prefix) = ($name, '');
    if (length($name) > 100) {
        my $i = rindex($name, '/', 154);
        croak "tar.zidx: pathname too long for ustar: $name"
            if $i < 0
            || (length($name) - $i - 1) > 100
            || $i > 155;
        $prefix = substr($name, 0, $i);
        $base   = substr($name, $i + 1);
    }

    my $hdr = pack(
        'a100 a8 a8 a8 a12 a12 A8 a1 a100 a6 a2 a32 a32 a8 a8 a155 x12',
        $base,
        sprintf('%07o',  $mode) . "\0",
        sprintf('%07o',  0) . "\0",
        sprintf('%07o',  0) . "\0",
        sprintf('%011o', $size) . "\0",
        sprintf('%011o', time) . "\0",
        '        ',
        $typeflag,
        '',
        "ustar\0",
        '00',
        '',
        '',
        sprintf('%07o', 0) . "\0",
        sprintf('%07o', 0) . "\0",
        $prefix,
    );

    my $sum = unpack('%16C*', $hdr);
    substr($hdr, 148, 8) = sprintf('%06o', $sum) . "\0 ";

    croak "tar.zidx: header pack produced unexpected length"
        unless length($hdr) == BLOCK_SIZE;

    return $hdr;
}

sub pad_to_block {
    my ($self, $len) = @_;
    my $rem = $len % BLOCK_SIZE;
    return $rem ? (BLOCK_SIZE - $rem) : 0;
}

sub pack_footer {
    my ($self, $idx_offset, $idx_size) = @_;
    return pack('a8 Q< Q< Q<', TAR_ZIDX_MAGIC, $idx_offset, $idx_size, 0);
}

sub parse_footer {
    my ($self, $buf) = @_;
    croak "tar.zidx: short footer" unless length($buf) == TAR_ZIDX_FOOTER_LEN;
    my ($magic, $idx_offset, $idx_size, undef) = unpack('a8 Q< Q< Q<', $buf);
    croak "tar.zidx: bad footer magic" unless $magic eq TAR_ZIDX_MAGIC;
    return ($idx_offset, $idx_size);
}

sub zstd_compress {
    my ($self, $bytes) = @_;
    my $out = Compress::Zstd::compress($bytes);
    croak "tar.zidx: Compress::Zstd::compress failed" unless defined $out;
    return $out;
}

sub zstd_decompress {
    my ($self, $bytes) = @_;
    my $out = Compress::Zstd::decompress($bytes);
    croak "tar.zidx: Compress::Zstd::decompress failed" unless defined $out;
    return $out;
}

# }}}

# {{{ Read API (Source role)

sub _build_index {
    my $self = shift;
    return $self->{+_INDEX} if $self->{+_INDEX};

    require App::Yath2::Log::Footer;
    require App::Yath2::Log;

    open(my $fh, '<', $self->{+PATH}) or croak "open $self->{+PATH}: $!";
    binmode $fh;

    my $size = -s $self->{+PATH};
    croak "tar.zidx: file too small for YATHFOOT trailer"
        if $size < App::Yath2::Log::Footer::FOOTER_SIZE();

    # Step 1: read the 64-byte YATHFOOT trailer at the end of the file.
    seek($fh, -App::Yath2::Log::Footer::FOOTER_SIZE(), SEEK_END)
        or croak "tar.zidx: seek YATHFOOT: $!";
    my $tail;
    read($fh, $tail, App::Yath2::Log::Footer::FOOTER_SIZE()) == App::Yath2::Log::Footer::FOOTER_SIZE()
        or croak "tar.zidx: short YATHFOOT read";

    my $info = App::Yath2::Log::Footer::unpack_footer($tail)
        or croak "tar.zidx: missing or invalid YATHFOOT trailer " . "(archive may be too old; minimum supported version: " . App::Yath2::Log->last_breaking_version . ")";

    croak "tar.zidx: trailer format_id is '$info->{format_id}', expected 'TAR'"
        unless $info->{format_id} eq App::Yath2::Log::Footer::FORMAT_ID_TAR();

    # Step 2: follow the trailer's format_ptr to the 32-byte zidx footer.
    my $zidx_offset = $info->{format_ptr};
    croak "tar.zidx: trailer format_ptr is 0; cannot locate zidx footer"
        unless $zidx_offset;

    seek($fh, $zidx_offset, SEEK_SET) or croak "tar.zidx: seek zidx footer: $!";
    my $foot;
    read($fh, $foot, TAR_ZIDX_FOOTER_LEN) == TAR_ZIDX_FOOTER_LEN
        or croak "tar.zidx: short zidx footer read";

    my ($idx_offset, $idx_size) = $self->parse_footer($foot);

    seek($fh, $idx_offset, SEEK_SET) or croak "seek index: $!";
    my $idx_bytes;
    read($fh, $idx_bytes, $idx_size) == $idx_size
        or croak "short index read";
    close $fh;

    my $json = $self->zstd_decompress($idx_bytes);
    $self->{+_INDEX} = decode_json($json);
    return $self->{+_INDEX};
}

sub list_files {
    my $self = shift;
    my $idx  = $self->_build_index;
    return grep { ($idx->{$_}{kind} // 'file') eq 'file' } keys %$idx;
}

# Directory entries explicitly recorded in the archive plus every
# parent-of-a-file path. Parent derivation lets older archives
# (pre-empty-dir-tracking) still report the directory shape that
# their files imply.
sub list_dirs {
    my $self = shift;
    my $idx  = $self->_build_index;

    my %dirs;
    for my $rel (keys %$idx) {
        if (($idx->{$rel}{kind} // 'file') eq 'dir') {
            $dirs{$rel} = 1;
            next;
        }
        my @parts = split m{/}, $rel;
        pop @parts;
        for my $i (1 .. scalar @parts) {
            $dirs{join('/', @parts[0 .. $i - 1])} = 1;
        }
    }
    return keys %dirs;
}

sub has_file {
    my ($self, $rel) = @_;
    my $entry = $self->_build_index->{$rel};
    return 0 unless $entry;
    return 0 if ($entry->{kind} // 'file') eq 'dir';
    return 1;
}

sub read_file {
    my ($self, $rel) = @_;
    my $entry = $self->_build_index->{$rel}
        or croak "no such file '$rel' in archive";
    croak "'$rel' is a directory entry, not a file"
        if ($entry->{kind} // 'file') eq 'dir';

    open(my $fh, '<', $self->{+PATH}) or croak "open $self->{+PATH}: $!";
    binmode $fh;
    seek($fh, $entry->{offset}, SEEK_SET) or croak "seek data: $!";
    my $stored;
    read($fh, $stored, $entry->{size}) == $entry->{size}
        or croak "short data read for '$rel'";
    close $fh;

    # 'inner' tells us whether the entry's payload is itself
    # zstd-compressed (legacy default) or stored verbatim. Verbatim
    # entries cover already-.zst source files; compressed entries
    # cover anything that was a plaintext file in the source logdir.
    my $inner = $entry->{inner} // 'zstd';
    my $plain = $inner eq 'none' ? $stored : $self->zstd_decompress($stored);

    open(my $sfh, '<', \$plain) or croak "open scalar: $!";
    return $sfh;
}

# Read raw stored bytes for $rel without unwrapping the inner zstd
# layer. Used by the Artifact handle when it wants .zst bytes verbatim.
sub _read_stored_bytes {
    my ($self, $rel) = @_;
    my $entry = $self->_build_index->{$rel}
        or croak "no such file '$rel' in archive";
    croak "'$rel' is a directory entry, not a file"
        if ($entry->{kind} // 'file') eq 'dir';

    open(my $fh, '<', $self->{+PATH}) or croak "open $self->{+PATH}: $!";
    binmode $fh;
    seek($fh, $entry->{offset}, SEEK_SET) or croak "seek data: $!";
    my $stored;
    read($fh, $stored, $entry->{size}) == $entry->{size}
        or croak "short data read for '$rel'";
    close $fh;
    return ($stored, $entry->{inner} // 'zstd');
}

# }}}

# {{{ Listing API

# Walk the index and bucket files by their "kind of host directory"
# so the listing methods can answer in O(1) once we cache the buckets.
sub _layout {
    my $self = shift;
    return $self->{_layout_cache} if $self->{_layout_cache};

    my $idx = $self->_build_index;

    my %global_services;    # name => 1
    my %runs;               # run_id => 1
    my %run_services;       # run_id => { name => 1 }
    my %run_jobs;           # run_id => { job_id => 1 }
    my %job_tries;          # "$rid/$jid" => { try => 1 }

    for my $rel (keys %$idx) {
        # services/<name>/...
        if ($rel =~ m{^services/([^/]+)(?:/|\z)}) {
            $global_services{$1} = 1;
            next;
        }

        # runs/<run_id>/...
        if ($rel =~ m{^runs/([^/]+)(?:/(.*))?\z}) {
            my ($rid, $rest) = ($1, $2);
            $runs{$rid} = 1;
            if (defined $rest && length $rest) {
                if ($rest =~ m{^services/([^/]+)(?:/|\z)}) {
                    $run_services{$rid}{$1} = 1;
                }
                elsif ($rest =~ m{^jobs/([^/]+)(?:/(.*))?\z}) {
                    my ($jid, $rest2) = ($1, $2);
                    $run_jobs{$rid}{$jid} = 1;
                    if (defined $rest2 && $rest2 =~ m{^([^/]+)(?:/|\z)}) {
                        $job_tries{"$rid/$jid"}{$1} = 1;
                    }
                }
            }
            next;
        }
    }

    return $self->{_layout_cache} = {
        global_services => \%global_services,
        runs            => \%runs,
        run_services    => \%run_services,
        run_jobs        => \%run_jobs,
        job_tries       => \%job_tries,
    };
}

sub _smart_sort {
    my @ids = @_;
    return () unless @ids;
    if (!grep { !/^\d+\z/ } @ids) {
        return sort { $a <=> $b } @ids;
    }
    return sort @ids;
}

sub services {
    my ($self, $run_id) = @_;
    my $layout = $self->_layout;

    if (defined $run_id) {
        croak "no such run: $run_id" unless $self->has_run($run_id);
        my $bucket = $layout->{run_services}{$run_id} || {};
        return sort keys %$bucket;
    }
    return sort keys %{$layout->{global_services}};
}

sub runs {
    my $self   = shift;
    my $layout = $self->_layout;
    return _smart_sort(keys %{$layout->{runs}});
}

sub jobs {
    my ($self, $run_id) = @_;
    croak "run_id is required"   unless defined $run_id;
    croak "no such run: $run_id" unless $self->has_run($run_id);
    my $layout = $self->_layout;
    return _smart_sort(keys %{$layout->{run_jobs}{$run_id} || {}});
}

sub tries {
    my ($self, $run_id, $job_id) = @_;
    croak "run_id is required"   unless defined $run_id;
    croak "job_id is required"   unless defined $job_id;
    croak "no such run: $run_id" unless $self->has_run($run_id);
    croak "no such job: $run_id/$job_id"
        unless $self->has_job($run_id, $job_id);
    my $layout = $self->_layout;
    return _smart_sort(keys %{$layout->{job_tries}{"$run_id/$job_id"} || {}});
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
    my $layout = $self->_layout;
    if (defined $run_id) {
        return 0 unless $self->has_run($run_id);
        return $layout->{run_services}{$run_id}{$name} ? 1 : 0;
    }
    return $layout->{global_services}{$name} ? 1 : 0;
}

sub has_run {
    my ($self, $run_id) = @_;
    return 0 unless defined $run_id && length $run_id;
    return 0 if $run_id =~ m{/};
    my $layout = $self->_layout;
    return $layout->{runs}{$run_id} ? 1 : 0;
}

sub has_job {
    my ($self, $run_id, $job_id) = @_;
    return 0 unless $self->has_run($run_id);
    return 0 unless defined $job_id && length $job_id;
    return 0 if $job_id =~ m{/};
    my $layout = $self->_layout;
    return $layout->{run_jobs}{$run_id}{$job_id} ? 1 : 0;
}

sub has_try {
    my ($self, $run_id, $job_id, $job_try) = @_;
    return 0 unless $self->has_job($run_id, $job_id);
    return 0 unless defined $job_try && length $job_try;
    return 0 if $job_try =~ m{/};
    my $layout = $self->_layout;
    return $layout->{job_tries}{"$run_id/$job_id"}{$job_try} ? 1 : 0;
}

# }}}

# {{{ Producer iterators
#
# API notes (discovered from TarZIdx.pm itself):
#   - Existence check: has_file($rel) => bool (uses index direct lookup)
#   - Content read:    read_file($rel) => filehandle (decompresses inner zstd)
#   - Enumeration:     runs(), jobs($run_id), services($run_id?), tries($run_id,$job_id)
#   - .sealed files are preserved through archive creation (_scan_source_tree walks
#     all files including dotfiles; no filter excludes them). No archive-side change needed.
#
# Tarballs are always post-mortem snapshots: state is always 'sealed' regardless
# of whether a .sealed marker is present. The marker contents (pass/exit/timestamps)
# are read when available to populate the descriptor.

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
    # Tarballs do not currently carry collector subtrees. Return an empty iterator.
    return App::Yath2::Log::Iterator::Producers->new(
        next_cb => sub { return undef },
    );
}

sub _build_run_producer {
    my ($self, $id) = @_;
    my $sealed = $self->_read_sealed_tar("runs/$id/.sealed");
    return App::Yath2::Log::Producer::Run->new(
        id            => $id,
        kind          => 'run',
        parent_id     => undef,
        run_id        => $id,
        state         => 'sealed',    # tarballs are always post-mortem
        started_at    => $sealed ? $sealed->{started_at} : undef,
        ended_at      => $sealed ? $sealed->{sealed_at}  : undef,
        pass          => $sealed ? $sealed->{pass}       : undef,
        exit          => $sealed ? $sealed->{exit}       : undef,
        log           => $self,
        artifact_refs => $self->_run_artifact_refs_tar($id),
    );
}

sub _build_job_producer {
    my ($self, $run_id, $jid, $try) = @_;
    my $base   = "runs/$run_id/jobs/$jid/$try";
    my $sealed = $self->_read_sealed_tar("$base/.sealed");
    my $refs   = $self->_job_artifact_refs_tar($run_id, $jid, $try);
    return App::Yath2::Log::Producer::Job->new(
        id               => $jid,
        kind             => 'job',
        parent_id        => $run_id,
        run_id           => $run_id,
        try              => $try,
        state            => 'sealed',    # tarballs are always post-mortem
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
    my $sealed = $self->_read_sealed_tar("$base/.sealed");
    return App::Yath2::Log::Producer::Service->new(
        id            => $sid,
        kind          => 'service',
        parent_id     => $run_id,
        run_id        => $run_id,
        state         => 'sealed',    # tarballs are always post-mortem
        started_at    => $sealed ? $sealed->{started_at} : undef,
        ended_at      => $sealed ? $sealed->{sealed_at}  : undef,
        log           => $self,
        artifact_refs => {},          # Extended in Stage 2
    );
}

sub _read_sealed_tar {
    my ($self, $rel) = @_;
    return undef unless $self->has_file($rel);

    my $fh;
    my $ok = eval { $fh = $self->read_file($rel); 1 };
    unless ($ok) {
        warn "Failed to read .sealed marker '$rel': $@";
        return undef;
    }
    return undef unless defined $fh;

    my $line = readline($fh);
    close($fh);
    return undef unless defined $line && length $line;

    my $data;
    $ok = eval { $data = decode_json($line); 1 };
    unless ($ok) {
        warn "Failed to decode .sealed marker '$rel': $@";
        return undef;
    }
    return undef unless ref $data eq 'HASH';
    return $data;
}

sub _run_artifact_refs_tar {
    my ($self, $id) = @_;
    my $base = "runs/$id";
    my %refs;
    for my $kind (qw/spec report events/) {
        for my $rel ("$base/$kind.jsonl", "$base/$kind.jsonl.zst") {
            if ($self->has_file($rel)) {
                $refs{$kind} = $rel;
                last;
            }
        }
    }
    return \%refs;
}

sub _job_artifact_refs_tar {
    my ($self, $run_id, $jid, $try) = @_;
    my $base = "runs/$run_id/jobs/$jid/$try";
    my %refs;
    for my $kind (qw/spec report events stdout stderr/) {
        for my $rel ("$base/$kind.jsonl", "$base/$kind.jsonl.zst") {
            if ($self->has_file($rel)) {
                $refs{$kind} = $rel;
                last;
            }
        }
    }
    return \%refs;
}

# }}}

# {{{ Artifacts handle

# artifacts() -- mirror the Directory positional/hashref dispatch.
sub artifacts {
    my $self = shift;

    return $self->_artifacts_from_args(@_) if @_ == 1 && ref($_[0]) eq 'HASH';
    return $self->_artifacts_root unless @_;

    my @args = @_;

    if (@args == 1) {
        my $arg = $args[0];
        if (defined $arg && $arg =~ /^\d+\z/) {
            return $self->_artifacts_from_args({run_id => $arg});
        }
        if (defined $arg && $self->has_service($arg)) {
            return $self->_artifacts_from_args({service => $arg});
        }
        return $self->_artifacts_from_args({run_id => $arg});
    }

    if (@args == 2) {
        my ($run_id, $second) = @args;
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
        live => 0,
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
        live => 0,
    );
}

# }}}

# {{{ Artifact backend primitives
#
# The archive's index records each entry under its source-tree path
# (no trailing .zst when the source was already-.zst, otherwise the
# stored entry name is "$rel.zst" but the index key is the source rel).
# To honour the Artifact contract -- which probes both ".../events.jsonl"
# and ".../events.jsonl.zst" -- we map the "with .zst suffix" probe
# back to the suffix-less index key when needed.

# Returns ($exists, $is_zst). For TarZIdx, $is_zst tells the caller
# whether the bytes returned by _artifact_read are zstd-compressed
# (i.e. need a decompress to be plaintext).
sub _artifact_exists {
    my ($self, $rel) = @_;
    my $idx = $self->_build_index;

    # Direct hit (matches the source path the writer used).
    if (my $entry = $idx->{$rel}) {
        return (0, 0) if ($entry->{kind} // 'file') eq 'dir';
        my $inner = $entry->{inner} // 'zstd';
        # is_zst from the reader's perspective = "do the bytes
        # _artifact_read returns end up zstd-shaped?". inner='plain'
        # means stored is plaintext, so always 0. inner='none' means
        # stored is the source's .zst bytes verbatim, so 1. inner='zstd'
        # means stored is zstd-wrapped plaintext: 1 only when caller
        # asked for the .zst variant.
        my $is_zst;
        if    ($inner eq 'plain') { $is_zst = 0 }
        elsif ($inner eq 'none')  { $is_zst = 1 }
        else                      { $is_zst = $rel =~ /\.zst\z/ ? 1 : 0 }
        return (1, $is_zst);
    }

    # Caller probed the .zst variant. Strip and look up the bare key.
    if ($rel =~ /\.zst\z/) {
        (my $stripped = $rel) =~ s/\.zst\z//;
        if (my $entry = $idx->{$stripped}) {
            return (0, 0) if ($entry->{kind} // 'file') eq 'dir';
            my $inner = $entry->{inner} // 'zstd';
            # inner='plain': stored is plaintext, no .zst variant exists.
            return (0, 0) if $inner eq 'plain';
            # Otherwise the stored bytes are zstd-wrapped (inner=zstd).
            return (1, 1);
        }
    }

    return (0, 0);
}

# Read raw artifact bytes. For TarZIdx this returns:
#
#   - For a plain index hit on a non-.zst path: the decompressed bytes
#     (matches Directory's "this is a plaintext file" semantics).
#   - For a plain index hit on a .zst path: the verbatim stored bytes
#     (matches Directory's "this is a .zst file" semantics).
#   - For a probe on the .zst variant of a plaintext source (e.g.
#     'foo.jsonl.zst' when the index key is 'foo.jsonl'): the stored
#     zstd-wrapped bytes.
sub _artifact_read {
    my ($self, $rel) = @_;
    my $idx = $self->_build_index;

    my $entry    = $idx->{$rel};
    my $rel_real = $rel;

    if (!$entry && $rel =~ /\.zst\z/) {
        (my $stripped = $rel) =~ s/\.zst\z//;
        $entry    = $idx->{$stripped};
        $rel_real = $stripped if $entry;
    }

    croak "no such file in archive: $rel" unless $entry;
    croak "'$rel' is a directory entry, not a file"
        if ($entry->{kind} // 'file') eq 'dir';

    my ($stored, $inner) = $self->_read_stored_bytes($rel_real);

    my $caller_wants_zst = $rel =~ /\.zst\z/ ? 1 : 0;
    if ($caller_wants_zst) {
        # Caller asked for .zst-shaped bytes. inner=zstd / inner=none
        # both mean stored is already zstd-shaped (compressed plaintext
        # or untouched .zst source). inner=plain means stored is
        # plaintext: have to compress on-the-fly to satisfy the request.
        return $self->zstd_compress($stored) if $inner eq 'plain';
        return $stored;
    }

    # Caller asked for the non-.zst path.
    return $stored if $inner eq 'plain';
    if ($inner eq 'none') {
        # Source was already .zst, stored verbatim; bytes are
        # zstd-shaped (multi-frame in jsonl case). Decompress.
        return $self->_decompress_jsonl_bytes($stored);
    }

    # inner=zstd, caller wants plaintext: decompress.
    return $self->zstd_decompress($stored);
}

# Open a filehandle for $rel. Returns a scalar-backed fh of the
# decompressed-or-verbatim bytes (whatever _artifact_read would
# return).
sub _artifact_open_fh {
    my ($self, $rel) = @_;
    my $bytes = $self->_artifact_read($rel);
    open(my $sfh, '<', \$bytes) or croak "open scalar fh: $!";
    return $sfh;
}

# Decompress zstd-wrapped jsonl bytes (multi-frame or single-frame).
sub _decompress_jsonl_bytes {
    my ($self, $bytes) = @_;

    my $out    = '';
    my $offset = 0;
    while ($offset < length $bytes) {
        my $size = zstd_frame_size(substr($bytes, $offset));
        croak "incomplete zstd frame in jsonl bytes" unless defined $size;
        my $frame = substr($bytes, $offset, $size);
        $offset += $size;
        my $plain = Compress::Zstd::decompress($frame);
        croak "zstd decompress failed in jsonl bytes" unless defined $plain;
        $out .= $plain;
    }
    return $out;
}

# Records-backed iterator: decompress the entire stem in one shot,
# split on newlines, decode each line. Returns an arrayref or undef
# if the file does not exist.
sub _artifact_iter_records {
    my ($self, $base, $stem) = @_;
    return undef unless defined $stem && length $stem;

    my $rel     = defined $base && length $base ? "$base/$stem" : $stem;
    my $rel_zst = "$rel.zst";
    my $idx     = $self->_build_index;

    my $entry = $idx->{$rel} || $idx->{$rel_zst};
    return undef unless $entry;

    # Resolve to the index key the entry actually lives at.
    my $hit_rel = $idx->{$rel} ? $rel : $rel_zst;
    my ($stored, $inner) = $self->_read_stored_bytes($hit_rel);

    my $plain;
    if ($inner eq 'plain') {
        # Stored verbatim as plaintext (compress=0 archive).
        $plain = $stored;
    }
    elsif ($inner eq 'none') {
        # Already-.zst source: the source bytes are themselves a
        # multi-frame zstd stream (one record per frame).
        $plain = $self->_decompress_jsonl_bytes($stored);
    }
    else {
        # Plaintext source wrapped in one outer zstd frame.
        $plain = $self->zstd_decompress($stored);
    }

    my @records;
    for my $line (split /\n/, $plain) {
        next unless length $line;
        my $decoded;
        my $ok  = eval { $decoded = decode_json($line); 1 };
        my $err = $@;
        unless ($ok) {
            chomp $err;
            warn "Skipping JSONL line that failed to decode in tar.zidx '$hit_rel': $err\n";
            next;
        }
        push @records => $decoded;
    }

    return \@records;
}

# Sorted basenames of $rel (a directory). Returns () when missing.
sub _artifact_list_dir {
    my ($self, $rel) = @_;
    my $idx    = $self->_build_index;
    my $prefix = "$rel/";
    my %names;
    for my $key (keys %$idx) {
        next unless rindex($key, $prefix, 0) == 0;
        my $rest = substr($key, length $prefix);
        next unless length $rest;
        # Skip nested entries (only direct children).
        next if $rest =~ m{/};
        # Skip directory entries.
        next if ($idx->{$key}{kind} // 'file') eq 'dir';
        $names{$rest} = 1;
    }
    return sort keys %names;
}

# tar.zidx archives are sealed: every entry's offset/size lives in the
# zstd-compressed index that pins the trailer. Mutating a single entry
# in place would invalidate the index. Callers that want to amend an
# archive must extract -> mutate the directory -> re-archive.
sub _artifact_save {
    my ($self, %p) = @_;
    croak "tar.zidx archives are read-only; " . "extract first, modify the directory, then re-archive";
}

# }}}

# {{{ Iterator (depth-first walk)
#
# Mirrors App::Yath2::Log::Directory's depth-first iterator but reads
# bytes from the tar via _artifact_iter_records (records are already in
# memory). Sealed-only: tar.zidx archives never go live. EOE flips
# true once the iterator stack is empty AND nothing remains to be
# read.

sub _walk_state {
    my $self = shift;
    return $self->{+_WALK} //= {
        stack => [
            $self->_open_artifact_walk(
                base          => 'services/harness',
                run_id        => undef,
                job_id        => undef,
                job_try       => undef,
                service       => 'harness',
                collector_pid => undef,
            ),
        ],
    };
}

# Build a stack entry for the given collector base. The 'records' field
# is an arrayref of decoded events (consumed in order). 'idx' tracks
# the next record to serve.
sub _open_artifact_walk {
    my ($self, %args) = @_;

    my $base    = $args{base};
    my $records = $self->_artifact_iter_records($base, 'events.jsonl') || [];

    return {
        records => $records,
        idx     => 0,
        base    => $base,
        ident   => {
            (defined $args{run_id}  ? (run_id       => $args{run_id})  : ()),
            (defined $args{job_id}  ? (job_id       => $args{job_id})  : ()),
            (defined $args{job_try} ? (job_try      => $args{job_try}) : ()),
            (defined $args{service} ? (service_name => $args{service}) : ()),
        },
        collector_pid => $args{collector_pid},
    };
}

sub _facet {
    my ($self, $event, $name) = @_;
    return undef unless ref($event) eq 'HASH';
    my $fd = $event->{facet_data};
    return undef unless ref($fd) eq 'HASH';
    return $fd->{$name};
}

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

# Pull one record from the iterator. Depth-first: try the top of
# stack first; on EOF walk down to older readers so the parent can
# produce a harness_collector_end that closes the child.
sub event {
    my ($self, $timeout) = @_;

    my $walk  = $self->_walk_state;
    my $stack = $walk->{stack};

    while (1) {
        last unless @$stack;

        my $got;
        my $owner;
        for (my $i = $#$stack; $i >= 0; $i--) {
            my $entry = $stack->[$i];
            if ($entry->{idx} < scalar @{$entry->{records}}) {
                $got   = $entry->{records}[$entry->{idx}++];
                $owner = $entry;
                last;
            }
        }

        if (defined $got) {
            if (my $start = $self->_facet($got, 'harness_collector_start')) {
                my $cpid = $start->{collector_pid};
                $self->{+_SEEN_STARTS}{$cpid} = $start if defined $cpid;
                my $child_base = $self->_base_for_collector_start($start);
                if (defined $child_base) {
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
                    push @$stack => $self->_open_artifact_walk(%args);
                }
                return $self->_inject_identifiers($got, $owner->{ident});
            }

            if (my $end = $self->_facet($got, 'harness_collector_end')) {
                my $cpid = $end->{collector_pid};
                $self->{+_CLOSED_STARTS}{$cpid} = 1 if defined $cpid;
                return $self->_inject_identifiers($got, $owner->{ident});
            }

            return $self->_inject_identifiers($got, $owner->{ident});
        }

        # Nothing to read from any stacked reader. Pop drained tops.
        my $popped = 0;
        while (@$stack && $stack->[-1]{idx} >= scalar @{$stack->[-1]{records}}) {
            pop @$stack;
            $popped++;
        }
        last if !@$stack;
        # Otherwise loop and try reading again from a deeper entry.
    }

    return undef;
}

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
    my $walk  = $self->_walk_state;
    my $stack = $walk->{stack};

    # Drained any popped tops.
    while (@$stack) {
        my $top = $stack->[-1];
        if ($top->{idx} < scalar @{$top->{records}}) {
            return 0;
        }
        pop @$stack;
    }
    return 1;
}

sub reset {
    my $self = shift;
    delete $self->{+_WALK};
    delete $self->{+_SEEN_STARTS};
    delete $self->{+_CLOSED_STARTS};
    return;
}

# }}}

# {{{ Write API

# extract: walk the index, materialise every member into a directory.
# 'compressed=>0' (the default) decompresses zstd payloads on the way
# out and strips the .zst suffix from the resulting filenames.
# 'compressed=>1' preserves byte-for-byte (still strips one zstd
# layer if the entry was wrapped, since the in-archive format always
# zstd-compresses plaintext entries -- compressed=>1 just refers to
# the suffix).
sub extract {
    my ($self, $dir, %opts) = @_;
    croak "destination is required" unless defined $dir && length $dir;
    croak "destination '$dir' already exists and is non-empty"
        if -e $dir && -d $dir && _dir_non_empty($dir);

    my $compressed   = exists $opts{compressed} ? $opts{compressed} : 0;
    my $runs         = $opts{runs};
    my $exclude_runs = $opts{exclude_runs};
    croak "'runs' and 'exclude_runs' are mutually exclusive"
        if defined $runs && defined $exclude_runs;

    my $include_run = $self->_make_run_filter($runs, $exclude_runs);

    make_path($dir);
    require Test2::Harness2::Util::Zstd;
    require App::Yath2::Log::Directory;

    my $index = $self->_build_index;
    for my $rel (sort keys %$index) {
        next unless $include_run->($rel);
        my $entry = $index->{$rel};

        if (($entry->{kind} // 'file') eq 'dir') {
            my $abs = File::Spec->catdir($dir, $rel);
            make_path($abs) unless -d $abs;
            next;
        }

        $self->_extract_one_entry($dir, $rel, $entry, $compressed);
    }

    return App::Yath2::Log::Directory->new(path => $dir, live => 0);
}

# Build the include-this-rel-path predicate honoring runs /
# exclude_runs filters. Returns a coderef that takes a relative path
# and returns true when the path should be extracted.
sub _make_run_filter {
    my ($self, $runs, $exclude_runs) = @_;
    return sub {
        my ($rel) = @_;
        return 1 unless $rel =~ m{^runs/([^/]+)(?:/|\z)};
        my $rid = $1;
        if (defined $runs) {
            return scalar grep { $_ eq $rid } @$runs;
        }
        if (defined $exclude_runs) {
            return scalar(grep { $_ eq $rid } @$exclude_runs) ? 0 : 1;
        }
        return 1;
    };
}

# Extract one file entry from the archive into the destination
# directory, honoring the caller's compressed/uncompressed preference.
sub _extract_one_entry {
    my ($self, $dir, $rel, $entry, $compressed) = @_;

    # `compressed=>1` keeps the original suffix shape: files that
    # were already .zst keep the suffix; plaintext sources gain
    # one (since they are stored zstd-wrapped). `compressed=>0`
    # always drops to plaintext and strips the .zst suffix.
    my $out_rel;
    if ($compressed) {
        $out_rel = $rel =~ /\.zst\z/ ? $rel : "$rel.zst";
    }
    else {
        $out_rel = $rel;
    }
    # `compressed=>1` keeps the original bytes (including the
    # outer zstd wrap); `compressed=>0` strips one layer and
    # emits the plaintext.
    my $out_abs = File::Spec->catfile($dir, $out_rel);
    my $parent  = dirname($out_abs);
    make_path($parent) unless -d $parent;

    my $stored = $self->_read_entry_bytes($rel, $entry);
    my $inner  = $entry->{inner} // 'zstd';

    my $payload;
    if ($compressed) {
        # Caller wants the verbatim-suffixed bytes. inner='zstd'
        # and inner='none' both mean stored is already zstd-shaped.
        # inner='plain' (compress=0 archive) means stored is
        # plaintext; compress on the way out so the extracted
        # *.zst file holds zstd bytes as expected.
        $payload = $inner eq 'plain' ? $self->zstd_compress($stored) : $stored;
    }
    else {
        $payload =
            ($inner eq 'none' || $inner eq 'plain')
            ? $stored
            : $self->zstd_decompress($stored);

        # When the original source was already .zst (inner=='none')
        # and the caller asked for plaintext, the file extension
        # in the archive carries '.zst'. Decompress the payload
        # and strip the suffix from the output rel-path so the
        # extracted form is a real plaintext file. The source may
        # be multi-frame (jsonl.zst is one frame per record), so
        # walk all frames concatenating decoded payloads.
        if ($inner eq 'none' && $rel =~ /\.zst\z/) {
            $payload = _decompress_multi_frame($payload);
            (my $stripped = $rel) =~ s/\.zst\z//;
            $out_abs = File::Spec->catfile($dir, $stripped);
            $parent  = dirname($out_abs);
            make_path($parent) unless -d $parent;
        }
    }

    open(my $out, '>', $out_abs) or croak "open $out_abs: $!";
    binmode $out;
    print $out $payload;
    close $out or croak "close $out_abs: $!";
}

# Read the stored bytes for a single index entry from the underlying
# tar.zidx file. Returns the raw stored bytes (zstd-wrapped or
# plaintext depending on inner).
sub _read_entry_bytes {
    my ($self, $rel, $entry) = @_;

    open(my $fh, '<', $self->{+PATH}) or croak "open $self->{+PATH}: $!";
    binmode $fh;
    seek($fh, $entry->{offset}, SEEK_SET) or croak "seek data: $!";
    my $stored;
    read($fh, $stored, $entry->{size}) == $entry->{size}
        or croak "short data read for '$rel'";
    close $fh;
    return $stored;
}

# archive($out, %opts).
#
# tar.zidx -> tar.zidx: copy the archive to $out, optionally filtering
# runs. tar.zidx -> sqlite: not implemented.
sub archive {
    my ($self, $out, %opts) = @_;
    croak "output path is required" unless defined $out && length $out;

    my $format = $opts{format} // 'tar.zidx';
    $format = 'tar.zidx' if $format eq 'tar';

    my $runs         = $opts{runs};
    my $exclude_runs = $opts{exclude_runs};
    croak "'runs' and 'exclude_runs' are mutually exclusive"
        if defined $runs && defined $exclude_runs;

    if ($format eq 'sqlite') {
        require App::Yath2::DB;
        croak "destination '$out' already exists" if -e $out;
        my $dest = App::Yath2::DB->new(file => $out);
        # seal => 1: single-archive sealed file; append YATHFOOT
        # trailer + zstd-compressed meta.json past the body.
        $dest->insert(
            $self,
            runs         => $runs,
            exclude_runs => $exclude_runs,
            seal         => 1,
        );
        return $dest;
    }

    if ($format ne 'tar.zidx') {
        croak "unknown archive format: $format";
    }

    # Filtered tar.zidx -> tar.zidx: extract to a tempdir then re-archive.
    # Unfiltered: copy bytes verbatim.
    if (!defined $runs && !defined $exclude_runs) {
        require File::Copy;
        File::Copy::copy($self->{+PATH}, $out)
            or croak "copy $self->{+PATH} -> $out: $!";
        require App::Yath2::Log::TarZIdx;
        return App::Yath2::Log::TarZIdx->new(path => $out);
    }

    require File::Temp;
    my $tmp = File::Temp::tempdir(CLEANUP => 1, TEMPLATE => 'yath-tarzidx-XXXXXX', TMPDIR => 1);
    require File::Path;
    File::Path::remove_tree($tmp, {keep_root => 1});
    $self->extract(
        $tmp,
        compressed   => 0,
        runs         => $runs,
        exclude_runs => $exclude_runs,
    );

    require App::Yath2::Log::Directory;
    my $dir = App::Yath2::Log::Directory->new(path => $tmp, live => 0);
    return $dir->archive($out);
}

# Internal: build a tar.zidx archive at this object's PATH from a
# source directory. Used by Directory->archive($out) which constructs
# a TarZIdx pointing at $out and then calls _write_from_directory.
sub _write_from_directory {
    my ($self, $src, %opts) = @_;
    my $out = $self->{+PATH};
    my $tmp = "$out.tmp.$$";

    my $abs_src = File::Spec->rel2abs($src);
    croak "source '$src' is not a directory" unless -d $abs_src;

    my $runs         = $opts{runs};
    my $exclude_runs = $opts{exclude_runs};
    croak "'runs' and 'exclude_runs' are mutually exclusive"
        if defined $runs && defined $exclude_runs;

    # compress=1 (default): wrap non-zst bodies in zstd, store .zst
    # bodies verbatim. compress=0: never zstd anything; decompress
    # any source .zst on the way out so the archive carries plaintext.
    my $compress = exists $opts{compress} ? ($opts{compress} ? 1 : 0) : 1;

    my $include_run = $self->_make_archive_run_filter($runs, $exclude_runs);

    open(my $fh, '>', $tmp) or croak "open $tmp: $!";
    binmode $fh;

    my ($file_entries, $dir_entries) = $self->_scan_source_tree($abs_src, $include_run);

    my $inline_entries = $self->_collect_inline_entries($opts{extra_files});

    my %index;

    $self->_write_dir_entries($fh, $dir_entries, \%index);

    my @all_files = $self->_combine_file_entries($file_entries, $inline_entries);

    for my $entry (sort { $a->[0] cmp $b->[0] } @all_files) {
        $self->_write_file_entry($fh, $entry, $compress, \%index);
    }

    my ($idx_offset, $idx_len) = $self->_write_index_entry($fh, \%index);

    print $fh ("\0" x (BLOCK_SIZE * 2));

    # Capture the offset of the 32-byte zidx footer before writing
    # it; the YATHFOOT trailer's format_ptr points here.
    my $zidx_footer_offset = tell $fh;
    print $fh $self->pack_footer($idx_offset, $idx_len);
    my $body_size = tell $fh;

    $self->_write_meta_trailer($fh, $opts{meta_json_bytes}, $body_size, $zidx_footer_offset);

    close $fh or croak "close $tmp: $!";

    rename($tmp, $out) or croak "rename $tmp -> $out: $!";

    # Force re-read of the index next time list_files / has_file
    # / read_file is called.
    delete $self->{+_INDEX};
    delete $self->{_layout_cache};

    return $out;
}

# Build the include-this-rel-path predicate for archive writes. Like
# _make_run_filter but also skips the LIVE sentinel and only matches
# numeric run ids.
sub _make_archive_run_filter {
    my ($self, $runs, $exclude_runs) = @_;
    return sub {
        my ($rel) = @_;
        # The LIVE sentinel never goes into archives.
        return 0 if $rel eq 'LIVE';
        return 1 unless $rel =~ m{^runs/(\d+)(?:/|\z)};
        my $rid = $1;
        if (defined $runs) {
            return scalar grep { $_ eq $rid } @$runs;
        }
        if (defined $exclude_runs) {
            return scalar(grep { $_ eq $rid } @$exclude_runs) ? 0 : 1;
        }
        return 1;
    };
}

# Walk the source tree and collect file / dir entries, honoring the
# include_run filter. Returns (\@file_entries, \@dir_entries) where
# each file entry is [rel, abs_path] and each dir entry is a rel path.
sub _scan_source_tree {
    my ($self, $abs_src, $include_run) = @_;

    my @file_entries;
    my @dir_entries;
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                my $rel = File::Spec->abs2rel($_, $abs_src);
                return if $rel eq '.';
                $rel =~ s{\\}{/}g;
                return unless $include_run->($rel);
                if (-f $_) {
                    push @file_entries => [$rel, $_];
                }
                elsif (-d $_) {
                    push @dir_entries => $rel;
                }
            },
        },
        $abs_src,
    );

    return (\@file_entries, \@dir_entries);
}

# Inline content entries (not from disk) injected by the caller.
# Used to drop a meta.json into the archive root at seal time
# without first writing it back into the source dir. Each entry
# is [rel, raw_bytes]. Returns an arrayref.
sub _collect_inline_entries {
    my ($self, $extras) = @_;

    my @inline_entries;
    if ($extras) {
        for my $name (sort keys %$extras) {
            # Filter out anything explicitly named LIVE for safety,
            # though the caller should never ask.
            next if $name eq 'LIVE';
            push @inline_entries => [$name, $extras->{$name}];
        }
    }
    return \@inline_entries;
}

# Write the directory entries first so the on-disk tar walks
# parent-before-children. Empty payloads, typeflag '5'. Updates
# the %index hashref in place.
sub _write_dir_entries {
    my ($self, $fh, $dir_entries, $index) = @_;
    for my $rel (sort @$dir_entries) {
        my $stored = "$rel/";
        my $hdr    = $self->pack_ustar_header(
            $stored, 0,
            typeflag => '5',
            mode     => oct('0755'),
        );
        print $fh $hdr;
        my $data_offset = tell $fh;
        $index->{$rel} = {
            stored => $stored,
            offset => $data_offset,
            size   => 0,
            inner  => 'none',
            kind   => 'dir',
        };
    }
}

# Combine on-disk file entries with caller-supplied inline ones.
# Inline entries take precedence: drop any disk entry whose rel
# matches an inline name (or its .zst counterpart) so we never write
# two entries for the same logical file. Returns a list of
# [rel, kind, src] tuples.
sub _combine_file_entries {
    my ($self, $file_entries, $inline_entries) = @_;

    my %inline_names;
    for my $e (@$inline_entries) {
        $inline_names{$e->[0]} = 1;
        (my $alt = $e->[0]) =~ s/\.zst\z//;
        $inline_names{$alt} = 1;
        $inline_names{"$alt.zst"} = 1;
    }
    my @disk_kept = grep { !$inline_names{$_->[0]} } @$file_entries;

    return (
        (map { [$_->[0], 'disk',   $_->[1]] } @disk_kept),
        (map { [$_->[0], 'inline', $_->[1]] } @$inline_entries),
    );
}

# Write a single file entry (either disk or inline) to the tar at
# $fh, updating the %$index in place.
sub _write_file_entry {
    my ($self, $fh, $entry, $compress, $index) = @_;
    my ($rel, $kind, $src) = @$entry;

    my $raw = $self->_read_entry_source_bytes($kind, $src);

    my ($payload, $stored, $inner, $logical_rel) = $self->_payload_for_entry($rel, $raw, $compress);

    my $hdr = $self->pack_ustar_header($stored, length($payload));
    print $fh $hdr;
    my $data_offset = tell $fh;
    print $fh $payload;
    my $pad = $self->pad_to_block(length $payload);
    print $fh ("\0" x $pad) if $pad;

    $index->{$logical_rel} = {
        stored => $stored,
        offset => $data_offset,
        size   => length $payload,
        inner  => $inner,
        kind   => 'file',
    };
}

# Slurp the raw bytes for a single entry source. Disk entries are
# read from $src as a file path; inline entries return $src as-is.
sub _read_entry_source_bytes {
    my ($self, $kind, $src) = @_;
    if ($kind eq 'disk') {
        open(my $rfh, '<', $src) or croak "open $src: $!";
        binmode $rfh;
        local $/;
        my $raw = <$rfh>;
        close $rfh;
        return $raw;
    }
    return $src;    # inline bytes, already in-memory
}

# Decide the stored payload, stored name, inner kind, and the
# logical (index-key) rel for a single entry given the compress
# mode. Returns ($payload, $stored, $inner, $logical_rel).
sub _payload_for_entry {
    my ($self, $rel, $raw, $compress) = @_;

    # Default (compress=1): already-zstd-compressed source files
    # (the loggers' .json.zst / .jsonl.zst) are stored verbatim
    # with inner=>'none'; everything else is wrapped in an inner
    # zstd frame and recorded as inner=>'zstd'.
    # compress=0: store every body plaintext, decompressing source
    # .zst inputs first; rel/stored never carry the .zst suffix.
    my $is_zst = ($rel =~ /\.zst\z/);
    if (!$compress) {
        my $payload = $is_zst ? $self->_decompress_jsonl_bytes($raw) : $raw;
        (my $stored = $rel) =~ s/\.zst\z//;
        # 'plain' = stored bytes are plaintext (not zstd-wrapped).
        # Distinct from 'none' which means "stored bytes are the
        # source's already-zstd-compressed form, untouched".
        # Rewrite the logical key in the index so readers ask
        # for "events.jsonl" not "events.jsonl.zst" when looking
        # up entries.
        return ($payload, $stored, 'plain', $stored);
    }
    if ($is_zst) {
        return ($raw, $rel, 'none', $rel);
    }
    my $payload = $self->zstd_compress($raw);
    return ($payload, "$rel.zst", 'zstd', $rel);
}

# Write the special __index__.json.zst entry that carries the random-
# access map. Returns (idx_offset, idx_compressed_length) for use by
# the zidx footer.
sub _write_index_entry {
    my ($self, $fh, $index) = @_;

    my $idx_json       = encode_json($index);
    my $idx_compressed = $self->zstd_compress($idx_json);
    my $idx_hdr        = $self->pack_ustar_header(INDEX_ENTRY_NAME, length($idx_compressed));
    print $fh $idx_hdr;
    my $idx_offset = tell $fh;
    print $fh $idx_compressed;
    my $pad = $self->pad_to_block(length $idx_compressed);
    print $fh ("\0" x $pad) if $pad;
    return ($idx_offset, length $idx_compressed);
}

# Write the zstd-compressed meta.json blob plus the 64-byte YATHFOOT
# trailer that the unified footer parser consumes.
sub _write_meta_trailer {
    my ($self, $fh, $meta_bytes, $body_size, $zidx_footer_offset) = @_;

    require App::Yath2::Log::Footer;

    croak "_write_from_directory: missing meta_json_bytes for YATHFOOT trailer"
        unless defined $meta_bytes && length $meta_bytes;

    require Test2::Harness2::Util::Zstd;
    my $meta_zst    = Test2::Harness2::Util::Zstd::compress_blob($meta_bytes);
    my $meta_offset = tell $fh;
    print $fh $meta_zst;

    my $crc = App::Yath2::Log::Footer::crc32_of($meta_zst);

    my $trailer = App::Yath2::Log::Footer::pack_footer(
        format_id   => App::Yath2::Log::Footer::FORMAT_ID_TAR(),
        flags       => App::Yath2::Log::Footer::FLAG_META_COMPRESSED(),
        meta_offset => $meta_offset,
        meta_size   => length($meta_zst),
        meta_crc32  => $crc,
        body_size   => $body_size,
        format_ptr  => $zidx_footer_offset,
    );
    print $fh $trailer;
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

# Decompress a possibly-multi-frame zstd byte string. Single-file
# .json.zst snapshots are one frame; .jsonl.zst event streams
# concatenate one self-contained zstd frame per record, with the
# trailing newline baked into each frame.
sub _decompress_multi_frame {
    my ($bytes) = @_;

    my $out = '';
    while (length $bytes) {
        my $size = zstd_frame_size($bytes);
        croak "tar.zidx extract: incomplete zstd frame in payload"
            unless defined $size;
        my $frame = substr($bytes, 0, $size);
        substr($bytes, 0, $size) = '';

        my $plain = Compress::Zstd::decompress($frame);
        croak "tar.zidx extract: zstd decompress failed in payload"
            unless defined $plain;

        $out .= $plain;
    }

    return $out;
}

# }}}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Log::TarZIdx - tar.zidx-backed Log backend.

=head1 DESCRIPTION

Reads and writes the single in-tree archive format yath produces.
On disk the format is a USTAR-format tar followed by a 32-byte
footer; the tar carries per-entry payloads (each individually
zstd-compressed if the source was plaintext, or stored verbatim if
the source was already a C<.zst>-suffixed file) plus a special
index entry. The footer points at the index, which is a
zstd-compressed JSON map from relative path to entry metadata
(C<{stored, offset, size, inner}>).

C<inner> is C<'zstd'> when the entry's payload bytes are
zstd-compressed, or C<'none'> when the bytes are stored verbatim.

This backend implements the full reader API directly against the
archive: callers can drive C<services> / C<runs> / C<jobs> / C<tries>
listings, the C<artifacts(...)> handle factory, and the depth-first
C<event> iterator without first extracting the archive to a
filesystem tree.

=head1 ATTRIBUTES

=over 4

=item path (required)

The path to the C<.yath> file.

=back

=head1 METHODS

In addition to the inherited L<App::Yath2::Log> reader API:

=over 4

=item $new_dir = $tar->extract($dest_dir, compressed => $bool)

Extract the archive into a fresh directory. With
C<compressed =E<gt> 0> (the default for this backend, matching
C<yath extract>) every zstd-compressed member is decompressed on
the way out and the trailing C<.zst> suffix is stripped from the
output filename. With C<compressed =E<gt> 1> entries are written
verbatim with C<.zst> suffixes preserved. Returns a new
L<App::Yath2::Log::Directory> instance pointing at the
destination.

=item $arc = $tar->archive($out, %opts)

Re-archive this tar.zidx to C<$out>. Without filters this is a
plain bytes-on-disk copy. With C<runs> / C<exclude_runs> filters
the source is extracted to a tempdir, the filtered tree is
re-archived, and the new TarZIdx is returned.

=back

=head1 SEE ALSO

L<App::Yath2::Log> -- the base class / factory.

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
