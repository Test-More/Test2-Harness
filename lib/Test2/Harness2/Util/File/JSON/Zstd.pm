package Test2::Harness2::Util::File::JSON::Zstd;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/confess croak/;

use Test2::Harness2::Util::JSON qw/decode_json/;
use Test2::Harness2::Util::Zstd qw/compress_file_atomic decompress_file/;

use parent 'Test2::Harness2::Util::File::JSON';
use Object::HashBase;

# All read/write methods inherited from Util::File::JSON go through
# the file-bytes layer in Util::File. Override the byte-level read /
# write paths here so we can transparently compress and decompress
# while keeping the encode/decode JSON layer unchanged.

sub read {
    my $self = shift;
    my $bytes = decompress_file($self->{+NAME});

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
    return compress_file_atomic($self->{+NAME}, $self->encode(@_));
}

sub write {
    my $self = shift;
    return compress_file_atomic($self->{+NAME}, $self->encode(@_));
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
