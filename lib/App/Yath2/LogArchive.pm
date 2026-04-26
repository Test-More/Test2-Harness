package App::Yath2::LogArchive;
use strict;
use warnings;

use Carp qw/croak/;
use File::Spec ();

use App::Yath2::LogArchive::Format qw/detect_format reader_class_for writer_class_for/;
use Test2::Harness2::Util::JSON qw/decode_json/;
use Test2::Harness2::Util::Zstd qw/decompress_blob/;

sub new {
    my ($class, %args) = @_;

    if ($class eq __PACKAGE__) {
        my $path          = $args{path} // croak "path is required";
        my $format        = detect_format($path);
        my $backend_class = reader_class_for($format);
        return $backend_class->new(%args, format => $format);
    }

    my $self = bless {%args}, $class;
    $self->init if $self->can('init');
    return $self;
}

sub create {
    my ($class, %args) = @_;
    my $source = $args{source} // croak "source is required";
    croak "source '$source' is not a directory" unless -d $source;
    $args{path} // croak "path is required";

    # tar.zidx is the only archive format yath produces. Anything in
    # the args called 'format' is ignored.
    delete $args{format};
    my $format       = 'tar.zidx';
    my $writer_class = writer_class_for($format);
    return $writer_class->new(%args, format => $format)->write_archive;
}

# Shared high-level API. Backends inherit this.

sub artifacts {
    my $self = shift;
    my ($run_id, %opts) = $self->_parse_scope_args(@_);

    # Live logdirs and tar.zidx archives carry artifacts.json.zst
    # (zstd-compressed JSON). Extracted trees produced by
    # `yath extract` carry artifacts.json (plaintext, with .zst
    # stripped from key paths to match the on-disk layout). Try the
    # compressed shape first; fall back to the plaintext shape.
    my $rel_zst = defined $run_id ? "runs/$run_id/artifacts.json.zst" : 'artifacts.json.zst';
    my $rel_pln = defined $run_id ? "runs/$run_id/artifacts.json"     : 'artifacts.json';

    if ($self->has_file($rel_zst)) {
        my $fh    = $self->read_file($rel_zst);
        my $bytes = do { local $/; <$fh> };
        close $fh;

        # dict_bytes is a Role::Source contract method; every backend
        # provides it (returns undef when no dict is bundled).
        my $dict_bytes = $self->dict_bytes;
        my $json = decompress_blob(
            $bytes,
            ($dict_bytes ? (dict_bytes => $dict_bytes) : ()),
        );
        return decode_json($json);
    }

    if ($self->has_file($rel_pln)) {
        my $fh   = $self->read_file($rel_pln);
        my $json = do { local $/; <$fh> };
        close $fh;
        return decode_json($json);
    }

    return {};
}

sub runs {
    my ($self, %opts) = @_;

    my %runs;
    for my $path ($self->list_files) {
        next unless $path =~ m{^runs/([^/]+)/};
        my $id = $1;
        if ($opts{include_empty}) {
            $runs{$id} = 1;
        }
        else {
            # Accept either the live (.zst) or extracted (plain)
            # manifest filename; both shapes are valid sources.
            $runs{$id} = 1
                if $path eq "runs/$id/artifacts.json.zst"
                || $path eq "runs/$id/artifacts.json";
        }
    }
    return sort keys %runs;
}

sub services {
    my $self = shift;
    my ($run_id, %opts) = $self->_parse_scope_args(@_);

    my $art    = $self->artifacts(defined $run_id ? ($run_id) : ());
    my $prefix = defined $run_id ? "runs/$run_id/services/" : 'services/';

    my %names;
    for my $key (keys %$art) {
        next unless $key =~ m{^\Q$prefix\E([^/.]+)\.[^/]+\z};
        $names{$1} = 1;
    }
    return sort keys %names;
}

sub rogue_files {
    my $self = shift;
    my ($run_id, %opts) = $self->_parse_scope_args(@_);

    my $manifest = $self->artifacts(defined $run_id ? ($run_id) : ());
    my %known    = map { $_ => 1 } keys %$manifest;

    my @all = $self->list_files;
    my @rogue;
    if (defined $run_id) {
        my $prefix = "runs/$run_id/";
        for my $f (@all) {
            next unless index($f, $prefix) == 0;
            next if $f eq "${prefix}artifacts.json.zst";
            next if $f eq "${prefix}artifacts.json";
            next if $known{$f};
            push @rogue => $f;
        }
    }
    else {
        for my $f (@all) {
            next if $f =~ m{^runs/};
            next if $f eq 'artifacts.json.zst';
            next if $f eq 'artifacts.json';
            next if $f eq 'zstd-dict.bin';
            next if $known{$f};
            push @rogue => $f;
        }
    }
    return sort @rogue;
}

sub _parse_scope_args {
    my ($self, @args) = @_;
    if (@args % 2 == 1) {
        my $run_id = shift @args;
        return ($run_id, @args);
    }
    return (undef, @args);
}

1;
