package Test2::Harness2::Util::File::JSON::Zstd;
use strict;
use warnings;

# Can probably remove this in favor of FileMonitor and the reader/writer classes

our $VERSION = '2.000011';

use Carp qw/confess croak/;

use Test2::Harness2::Util::JSON qw/decode_json/;
use Test2::Harness2::Util::Zstd qw/compress_file_atomic decompress_file decompress_blob/;

use parent 'Test2::Harness2::Util::File::JSON';
use Object::HashBase qw/<dict_path/;

# All read/write methods inherited from Util::File::JSON go through
# the file-bytes layer in Util::File. Override the byte-level read /
# write paths here so we can transparently compress and decompress
# while keeping the encode/decode JSON layer unchanged.

sub read {
    my $self = shift;
    my $bytes = decompress_file(
        $self->{+NAME},
        ($self->{+DICT_PATH} ? (dict_path => $self->{+DICT_PATH}) : ()),
    );

    my $out;
    my $ok  = eval { $out = $self->decode($bytes); 1 };
    my $err = $@;
    confess "$self->{+NAME}: $err" unless $ok;
    return $out;
}

sub maybe_read {
    my $self = shift;
    return undef unless -e $self->{+NAME};
    return $self->read;
}

sub rewrite {
    my $self = shift;
    return compress_file_atomic(
        $self->{+NAME},
        $self->encode(@_),
        ($self->{+DICT_PATH} ? (dict_path => $self->{+DICT_PATH}) : ()),
    );
}

sub write {
    my $self = shift;
    return compress_file_atomic(
        $self->{+NAME},
        $self->encode(@_),
        ($self->{+DICT_PATH} ? (dict_path => $self->{+DICT_PATH}) : ()),
    );
}

# read_if_changed mirrors the base class but routes raw bytes through
# our zstd-aware reader instead of Util::Util::read_file.
sub read_if_changed {
    my $self = shift;

    my $cur = $self->_current_state;
    return () unless $self->changed;

    my $path = $self->{+NAME};
    unless (defined($cur) && -e $path) {
        $self->_record_state(undef);
        return (undef);
    }

    my $raw;
    my $raw_ok = eval {
        $raw = decompress_file(
            $path,
            ($self->{+DICT_PATH} ? (dict_path => $self->{+DICT_PATH}) : ()),
        );
        1;
    };
    my $raw_err = $@;
    unless ($raw_ok) {
        # An empty or partially-written file shows up as a decompress
        # failure here. Mirror the base class's "no content" handling:
        # report the absence as (undef) and record the state so we do
        # not loop on the same bad bytes.
        $self->_record_state($cur);
        return (undef);
    }

    unless (defined($raw) && length($raw)) {
        $self->_record_state($cur);
        return (undef);
    }

    my $data;
    my $ok  = eval { $data = $self->decode($raw); 1 };
    my $err = $@;
    confess "$path: $err" unless $ok;

    $self->_record_state($cur);
    return ($data);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::File::JSON::Zstd - JSON file with zstd compression on disk.

=head1 DESCRIPTION

Subclass of L<Test2::Harness2::Util::File::JSON> that compresses every
on-disk write with zstd and decompresses every read. Used for the
C<.json.zst> snapshot files yath produces under C<workdir/logs/>.

The on-disk format is a single zstd frame holding the encoded JSON
payload. Atomic writes go through L<Test2::Harness2::Util::Zstd>'s
C<compress_file_atomic>; reads through C<decompress_file>.

=head1 ATTRIBUTES

=over 4

=item dict_path

Optional. When set, every read and write uses the dictionary at the
given path. When unset, dict-less compression is used.

=back

=head1 SEE ALSO

L<Test2::Harness2::Util::File::JSON> -- plaintext sibling, used for
C<.json> files (extracted output, tests).

L<Test2::Harness2::Util::Zstd> -- shared zstd helper.

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
