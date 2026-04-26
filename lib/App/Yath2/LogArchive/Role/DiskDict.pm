package App::Yath2::LogArchive::Role::DiskDict;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Spec ();

use Role::Tiny;

# Concrete `dict_bytes` implementation for any LogArchive backend
# whose storage shape is "an on-disk root carrying a sibling
# zstd-dict.bin file". Composes the Role::Source dict_bytes contract
# (returns the dict bytes, or undef when none).
#
# Implementors must expose a `path` accessor (e.g. via
# Object::HashBase) returning the root directory; the role reads
# `<path>/zstd-dict.bin` in binary mode -- Test2::Harness2::Util::
# read_file goes through open_file which does not call binmode, and
# a CRLF-translating environment would corrupt the dict mid-read.
requires 'path';

sub dict_bytes {
    my $self = shift;
    my $abs  = File::Spec->catfile($self->path, 'zstd-dict.bin');
    return undef unless -f $abs;

    open(my $fh, '<', $abs) or croak "open '$abs': $!";
    binmode $fh;
    local $/;
    my $bytes = <$fh>;
    close $fh;
    return $bytes;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::LogArchive::Role::DiskDict - Sibling-file
implementation of the L<App::Yath2::LogArchive::Role::Source>
C<dict_bytes> contract.

=head1 SYNOPSIS

    package App::Yath2::LogArchive::Directory;
    use parent 'App::Yath2::LogArchive';
    use Object::HashBase qw/path format/;

    with 'App::Yath2::LogArchive::Role::Source',
         'App::Yath2::LogArchive::Role::DiskDict';

=head1 DESCRIPTION

Provides a single C<dict_bytes> method that reads
C<E<lt>pathE<gt>/zstd-dict.bin> from disk in binary mode and
returns its bytes (or C<undef> when the file does not exist).

Implementors must expose a C<path> accessor returning the root
directory the dict file lives next to; everything else is the
role's responsibility.

This is the right shape for any backend whose underlying storage
is a real directory tree -- the live workdir layout
(L<App::Yath2::LogArchive::Directory>), an extracted archive, an
NFS-mounted snapshot, etc. Backends whose dict lives I<inside> a
single file (e.g. L<App::Yath2::LogArchive::TarZIdx>, which
reads the dict at an offset within the archive) implement
C<dict_bytes> themselves.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=cut
