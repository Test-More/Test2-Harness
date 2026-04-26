package App::Yath2::Command::extract;
use strict;
use warnings;

our $VERSION = '2.000011';

use File::Path qw/make_path/;
use File::Spec ();
use File::Basename qw/dirname/;

use App::Yath2::LogArchive;
use Compress::Zstd ();
use Compress::Zstd::Decompressor;
use Compress::Zstd::DecompressionContext;
use Compress::Zstd::DecompressionDictionary;
use Test2::Harness2::Util::JSON qw/decode_json encode_pretty_json/;
use Test2::Harness2::Util::Zstd qw/decompress_blob zstd_frame_size/;

use Object::HashBase qw/<settings <args <env_vars <option_state <plugins/;

use Getopt::Yath;

use Role::Tiny::With;
with 'App::Yath2::Role::Command';

sub group { 'log parsing' }

sub summary  { "Extract a yath log archive" }
sub cli_args { "[--] archive_filename [destination]" }

sub description {
    return <<"    EOT";
Extract a yath log archive into a directory.

Required first argument: path to the archive file.

Optional second argument: destination directory. Defaults to './logs'.
The destination must NOT already exist; it will be created (along with
any missing parents) before extraction.

By default, every zstd-compressed entry in the archive is decompressed
on the way out and the trailing '.zst' suffix is stripped from the
output filename. The extracted tree is therefore directly
human-readable -- a 'foo.json.zst' entry lands as 'foo.json'. The
bundled dictionary (if present) is also written out to
'<dest>/zstd-dict.bin' so the extracted directory matches the
on-disk shape a live harness produces.

Pass --no-decompress to disable that behaviour and produce a
byte-for-byte extract that preserves '.zst' suffixes and stores
compressed bytes verbatim.
    EOT
}

sub args_include_tests { 0 }

sub run {
    my $self = shift;

    my $args = $self->args;
    shift @$args if @$args && $args->[0] eq '--';

    my $no_decompress = 0;
    my @rest;
    for my $arg (@$args) {
        if ($arg eq '--no-decompress') { $no_decompress = 1 }
        else                           { push @rest => $arg }
    }
    @$args = @rest;

    my $archive = shift @$args;
    die "archive_filename is required\n"
        unless defined $archive && length $archive;
    die "archive '$archive' does not exist\n" unless -e $archive;

    my $dest = shift @$args // './logs';

    die "extra arguments after destination\n" if @$args;

    die "destination '$dest' already exists\n" if -e $dest;

    make_path($dest) or die "could not create destination '$dest': $!\n"
        unless -d $dest;

    my $la = App::Yath2::LogArchive->new(path => $archive);

    print "Extracting '$archive' to '$dest' (format: " . _format_for($la) . ")\n";

    my $dict_bytes = $la->can('dict_bytes') ? $la->dict_bytes : undef;

    my $count = 0;
    for my $rel ($la->list_files) {
        my $is_zst  = $rel =~ /\.zst\z/;
        my $is_dict = $rel eq 'zstd-dict.bin';
        my $out_rel =
            ($no_decompress || !$is_zst || $is_dict)
            ? $rel
            : do { (my $r = $rel) =~ s/\.zst\z//; $r };

        my $abs    = File::Spec->catfile($dest, $out_rel);
        my $parent = dirname($abs);
        make_path($parent) unless -d $parent;

        my $rfh = $la->read_file($rel);
        binmode $rfh;
        my $bytes = do { local $/; <$rfh> };
        close $rfh;

        if (!$no_decompress && $is_zst && !$is_dict) {
            $bytes = _decompress_multi_frame($bytes, $dict_bytes);

            # The artifacts.json manifests at harness scope and per-run
            # scope key entries by relative path -- and those paths
            # were written with the live-logdir '.zst' suffixes. After
            # extract strips the suffix from filenames, the manifest
            # would still point at non-existent '.zst' paths. Rewrite
            # the keys to match the extracted shape so consumers
            # (yath replay, ad-hoc tooling) find the files.
            if (   $out_rel eq 'artifacts.json'
                || $out_rel =~ m{\Aruns/[^/]+/artifacts\.json\z})
            {
                $bytes = _rewrite_manifest_keys($bytes);
            }
        }

        open(my $out, '>', $abs) or die "open $abs: $!\n";
        binmode $out;
        print $out $bytes;
        close $out or die "close $abs: $!\n";
        $count++;
    }

    print "Extracted $count file(s)\n";
    return 0;
}

sub _format_for {
    my ($la) = @_;
    my $class = ref $la;
    return $class =~ s/^App::Yath2::LogArchive:://r;
}

# Strip trailing '.zst' from every key in the artifacts.json
# manifest so the on-disk extracted layout (where .zst suffixes
# have been removed) matches the manifest's path references.
sub _rewrite_manifest_keys {
    my ($json) = @_;
    my $data = decode_json($json);
    return $json unless ref($data) eq 'HASH';

    my %out;
    for my $key (keys %$data) {
        (my $new = $key) =~ s/\.zst\z//;
        $out{$new} = $data->{$key};
    }
    return encode_pretty_json(\%out);
}

# Decompress a possibly-multi-frame zstd byte string. The single
# .json.zst snapshots produce one frame; the .jsonl.zst event
# streams concatenate one self-contained zstd frame per record.
#
# Producers (the JSONL.zst writer, EventEmitter) do NOT embed an
# inter-record newline inside the compressed plaintext -- frames
# self-delimit -- so the extract command is responsible for
# reinserting exactly one newline between records when materializing
# extracted plaintext jsonl. We strip any trailing newlines from
# each frame's payload first so producers that did include one (the
# legacy plain JSONL writer through the same path, or older archives)
# still extract to a single-newline-per-record shape.
#
# Walks frames via zstd_frame_size for both the dict and no-dict
# paths; one frame is one record either way.
sub _decompress_multi_frame {
    my ($bytes, $dict_bytes) = @_;

    my $ddict;
    $ddict = Compress::Zstd::DecompressionDictionary->new($dict_bytes)
        if defined $dict_bytes;
    my $dctx = Compress::Zstd::DecompressionContext->new if $ddict;

    my @records;
    while (length $bytes) {
        my $size = zstd_frame_size($bytes);
        die "tar.zidx: incomplete zstd frame in extract payload\n"
            unless defined $size;
        my $frame = substr($bytes, 0, $size);
        substr($bytes, 0, $size) = '';

        my $plain =
              $ddict
            ? $dctx->decompress_using_dict($frame, $ddict)
            : Compress::Zstd::decompress($frame);
        die "tar.zidx: zstd decompress failed in extract payload\n"
            unless defined $plain;

        push @records => $plain;
    }

    return '' unless @records;

    # Single-frame snapshots (.json.zst): return the payload as-is;
    # there is no inter-record story to enforce, and a snapshot's
    # body may legitimately end without a newline.
    return $records[0] if @records == 1;

    # Multi-frame streams (.jsonl.zst): one record per line, exactly
    # one newline between records, trailing newline included so the
    # file is canonical jsonl.
    my $out = '';
    for my $r (@records) {
        $r =~ s/\n+\z//;
        $out .= $r . "\n";
    }
    return $out;
}

1;

__END__

=head1 POD IS AUTO-GENERATED
