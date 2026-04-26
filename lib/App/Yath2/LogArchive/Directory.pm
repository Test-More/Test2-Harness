package App::Yath2::LogArchive::Directory;
use strict;
use warnings;

use Carp qw/croak/;
use File::Find ();
use File::Spec ();
use Role::Tiny::With;

use parent 'App::Yath2::LogArchive';
use Object::HashBase qw/path format/;

with 'App::Yath2::LogArchive::Role::Source',
     'App::Yath2::LogArchive::Role::DiskDict';

sub viable { 1 }

sub init {
    my $self = shift;
    my $p    = $self->{+PATH} // croak "path is required";
    croak "path '$p' is not a directory" unless -d $p;
    return;
}

sub read_file {
    my ($self, $rel) = @_;
    my $abs = File::Spec->catfile($self->{+PATH}, $rel);
    open(my $fh, '<', $abs) or croak "read_file '$rel': $!";
    return $fh;
}

sub has_file {
    my ($self, $rel) = @_;
    my $abs = File::Spec->catfile($self->{+PATH}, $rel);
    return -f $abs ? 1 : 0;
}

sub list_files {
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
            # Live logdirs key the manifest by '.json.zst'; extracted
            # trees (post-`yath extract`) drop the suffix. Accept
            # either shape so a Directory backend works for both.
            $runs{$id} = 1
                if $path eq "runs/$id/artifacts.json.zst"
                || $path eq "runs/$id/artifacts.json";
        }
    }

    if ($opts{include_empty}) {
        my $runs_dir = File::Spec->catdir($self->{+PATH}, 'runs');
        if (-d $runs_dir && opendir(my $dh, $runs_dir)) {
            while (defined(my $entry = readdir($dh))) {
                next if $entry eq '.' || $entry eq '..';
                next unless -d File::Spec->catdir($runs_dir, $entry);
                $runs{$entry} = 1;
            }
            closedir($dh);
        }
    }

    return sort keys %runs;
}

sub close { }

1;
