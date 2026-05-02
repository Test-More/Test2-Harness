package App::Yath2::Command::extract;
use strict;
use warnings;

our $VERSION = '2.000011';

use File::Basename qw/dirname/;
use File::Find ();
use File::Path qw/make_path/;
use File::Spec ();

use App::Yath2::LogArchive;
use Compress::Zstd ();
use Test2::Harness2::Util::Zstd qw/zstd_frame_size/;

use Object::HashBase qw/<settings <args <env_vars <option_state <plugins/;

use Getopt::Yath;
include_options('App::Yath2::Options::Yath');

option_group {group => 'extract', category => 'Extract Options'} => sub {
    option no_decompress => (
        type        => 'Bool',
        default     => 0,
        description => 'Preserve .zst suffixes and store compressed bytes verbatim instead of decompressing on the way out.',
    );
};

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

Extraction is two-pass. First, every member of the archive is written
to disk verbatim, preserving its on-archive name. Second, every '.zst'
file in the extracted tree is decompressed in-place: the plaintext
lands at the '.zst'-stripped sibling and the original is removed.

Pass --no-decompress to skip the second pass and leave the extracted
tree byte-for-byte identical to the archive contents.
    EOT
}

sub args_include_tests { 0 }

sub run {
    my $self = shift;

    my $args = $self->args;
    shift @$args if @$args && $args->[0] eq '--';

    my $no_decompress = $self->{+SETTINGS}->extract->no_decompress ? 1 : 0;

    my $archive = shift @$args;
    unless (defined $archive && length $archive) {
        $archive = App::Yath2::LogArchive->find_latest($self->{+SETTINGS});
        print STDERR "yath extract: using latest archive: $archive\n"
            if defined $archive && length $archive;
    }
    die "archive_filename is required (no ./last_log.yath and no matching archive in tempdir)\n"
        unless defined $archive && length $archive;
    die "archive '$archive' does not exist\n" unless -e $archive;

    my $dest = shift @$args // './logs';

    die "extra arguments after destination\n" if @$args;

    die "destination '$dest' already exists\n" if -e $dest;

    make_path($dest) or die "could not create destination '$dest': $!\n"
        unless -d $dest;

    my $la = App::Yath2::LogArchive->open(path => $archive);

    print "Extracting '$archive' to '$dest' (format: " . _format_for($la) . ")\n";

    # Materialise every directory the archive recorded so empty
    # runs / jobs / services survive the round-trip; their existence
    # is the directory itself, not any file inside it.
    for my $rel ($la->list_dirs) {
        my $abs = File::Spec->catdir($dest, $rel);
        make_path($abs) unless -d $abs;
    }

    my $count = 0;
    for my $rel ($la->list_files) {
        my $abs    = File::Spec->catfile($dest, $rel);
        my $parent = dirname($abs);
        make_path($parent) unless -d $parent;

        my $rfh = $la->read_file($rel);
        binmode $rfh;
        my $bytes = do { local $/; <$rfh> };
        close $rfh;

        open(my $out, '>', $abs) or die "open $abs: $!\n";
        binmode $out;
        print $out $bytes;
        close $out or die "close $abs: $!\n";
        $count++;
    }

    print "Extracted $count file(s)\n";

    return 0 if $no_decompress;

    my $decompressed = _decompress_tree($dest);
    print "Decompressed $decompressed file(s)\n" if $decompressed;

    return 0;
}

sub _format_for {
    my ($la) = @_;
    my $class = ref $la;
    return $class =~ s/^App::Yath2::LogArchive:://r;
}

# Walk the extracted tree, decompress every .zst file in place to its
# '.zst'-stripped sibling, and remove the original. Multi-frame safe:
# .jsonl.zst stores one self-contained frame per record so concatenated
# decompression yields valid jsonl directly.
sub _decompress_tree {
    my ($root) = @_;
    my $count = 0;

    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                my $abs = $File::Find::name;
                return unless -f $abs;
                return unless $abs =~ /\.zst\z/;

                open(my $rfh, '<', $abs) or die "open $abs: $!\n";
                binmode $rfh;
                my $bytes = do { local $/; <$rfh> };
                close $rfh;

                my $plain = _decompress_multi_frame($bytes);

                (my $out_abs = $abs) =~ s/\.zst\z//;
                open(my $out, '>', $out_abs) or die "open $out_abs: $!\n";
                binmode $out;
                print $out $plain;
                close $out or die "close $out_abs: $!\n";

                unlink $abs or die "unlink $abs: $!\n";
                $count++;
            },
        },
        $root,
    );

    return $count;
}

# Decompress a possibly-multi-frame zstd byte string. Single .json.zst
# snapshots are one frame; .jsonl.zst event streams concatenate one
# self-contained zstd frame per record, with the trailing newline
# baked into each frame.
sub _decompress_multi_frame {
    my ($bytes) = @_;

    my $out = '';
    while (length $bytes) {
        my $size = zstd_frame_size($bytes);
        die "extract: incomplete zstd frame in payload\n"
            unless defined $size;
        my $frame = substr($bytes, 0, $size);
        substr($bytes, 0, $size) = '';

        my $plain = Compress::Zstd::decompress($frame);
        die "extract: zstd decompress failed in payload\n"
            unless defined $plain;

        $out .= $plain;
    }

    return $out;
}

1;

__END__

=head1 POD IS AUTO-GENERATED
