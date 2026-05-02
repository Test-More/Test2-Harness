package Test2::Harness2::Util::JSON;
use strict;
use warnings;

use Carp qw/confess croak/;
use Cpanel::JSON::XS();
use File::Temp qw/tempfile/;
use Importer Importer => 'import';

use Test2::Harness2::Util qw/write_file_atomic/;

our $VERSION = '2.000011';

our @EXPORT_OK = qw{
    decode_json
    decode_json_file
    decode_json_no_null
    decode_json_zst_file
    encode_json
    encode_json_file
    encode_pretty_json
    json_false
    json_true
    write_json_file_atomic
    write_json_zst_file_atomic
};

my $json   = Cpanel::JSON::XS->new->utf8(1)->convert_blessed(1)->allow_nonref(1);
my $ascii  = Cpanel::JSON::XS->new->ascii(1)->convert_blessed(1)->allow_nonref(1);
my $pretty = Cpanel::JSON::XS->new->ascii(1)->pretty(1)->canonical(1)->convert_blessed(1)->allow_nonref(1);

sub decode_json {
    my $out;
    confess($@) unless eval { $out = $json->decode(@_); 1 };
    $out;
}

sub encode_json {
    my $out;
    confess($@) unless eval { $out = $ascii->encode(@_); 1 };
    $out;
}

sub encode_pretty_json {
    my $out;
    confess($@) unless eval { $out = $pretty->encode(@_); 1 };
    $out;
}

sub decode_json_file {
    my ($file, %params) = @_;

    open(my $fh, '<', $file) or die "Could not open '$file': $!";
    my $json_text = do { local $/; <$fh> };

    if ($params{unlink}) {
        unlink($file) or warn "Could not unlink '$file': $!";
    }

    return decode_json($json_text);
}

sub encode_json_file {
    my ($data) = @_;
    my $json_text = encode_json($data);

    my ($fh, $file) = tempfile("$$-XXXXXX", TMPDIR => 1, SUFFIX => '.json', UNLINK => 0);
    print $fh $json_text;
    close($fh);

    return $file;
}

sub write_json_file_atomic {
    my ($path, $data) = @_;

    croak "path is required"         unless defined $path;
    croak "data hashref is required" unless defined $data;

    write_file_atomic($path, encode_pretty_json($data));
    return;
}

# Sibling of write_json_file_atomic that compresses the encoded JSON
# with zstd before the atomic rename. Used by every logger / service
# that writes a snapshot to a path under $logdir/ (.json.zst by
# convention).
sub write_json_zst_file_atomic {
    my ($path, $data) = @_;

    croak "path is required"         unless defined $path;
    croak "data hashref is required" unless defined $data;

    require Test2::Harness2::Util::Zstd;
    Test2::Harness2::Util::Zstd::compress_file_atomic(
        $path,
        encode_pretty_json($data),
    );
    return;
}

# Sibling of decode_json_file that reads a zstd-compressed JSON file.
sub decode_json_zst_file {
    my ($file, %opts) = @_;

    croak "file is required" unless defined $file;

    require Test2::Harness2::Util::Zstd;
    my $bytes = Test2::Harness2::Util::Zstd::decompress_file($file);

    if ($opts{unlink}) {
        unlink($file) or warn "Could not unlink '$file': $!";
    }

    return decode_json($bytes);
}

sub json_true  { Cpanel::JSON::XS->true }
sub json_false { Cpanel::JSON::XS->false }

# The null character (\0) round-trips through JSON as the escape
# sequence \u0000, but some JSON producers emit it raw, which neither
# we nor Cpanel::JSON::XS can round-trip cleanly. Escape every raw null
# (that is not already inside a backslash escape) to \u0000 before
# decoding. Leaves already-escaped nulls untouched.
sub decode_json_no_null {
    my ($input) = @_;

    my $escaped = $input;
    $escaped =~ s/(?<!\\)((?:\\)(?:0|u0000))/\\$1/g;

    my $out;
    my $ok = eval { $out = decode_json($escaped); 1 };
    my $err = $@;
    die "decode_json_no_null: $err" unless $ok;
    return $out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::JSON - Thin JSON helpers used across the harness.

=head1 SYNOPSIS

    use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

    my $json = encode_json({ ... });
    my $data = decode_json($json);

    use Test2::Harness2::Util::JSON qw/encode_json_file decode_json_file/;

    my $path = encode_json_file({ ... });           # writes to a tempfile
    my $data = decode_json_file($path, unlink => 1);

=head1 DESCRIPTION

Wraps L<Cpanel::JSON::XS> with the encoder/decoder configurations the harness
relies on (UTF-8, C<convert_blessed>, C<allow_nonref>, plus an ASCII-safe
encoder for messages that travel through plain handles, and a pretty/canonical
encoder for human-facing files). Also provides convenience helpers for
reading and writing whole JSON files.

=head1 EXPORTS

All exports are optional and must be requested explicitly.

=over 4

=item $json = encode_json($data)

Encode C<$data> to ASCII-safe JSON. Confesses on encoding errors.

=item $json = encode_pretty_json($data)

Encode C<$data> to ASCII-safe, pretty-printed, canonical (sorted-key) JSON,
suitable for files a human will read. Confesses on encoding errors.

=item $data = decode_json($json)

Decode UTF-8 JSON text. Confesses on decoding errors.

=item $path = encode_json_file($data)

Encode C<$data> with L</encode_json> and write it to a freshly-created tempfile
(C<$$-XXXXXX.json> in the system tempdir, with C<UNLINK =E<gt> 0> so the caller
controls cleanup). Returns the path to that file.

=item $data = decode_json_file($path, %params)

Slurp C<$path>, decode it via L</decode_json>, and return the result. With
C<unlink =E<gt> 1> the file is removed after reading (a warn-level diagnostic
fires if the unlink fails).

=item write_json_file_atomic($path, \%data)

Encode C<\%data> with L</encode_pretty_json> and write it to C<$path>
atomically: the encoder writes a sibling tempfile in the same directory
and C<rename>s it over the target, so readers never see a partial file.
Throws on any I/O failure; the tempfile is cleaned up on error.

=item $bool = json_true()

=item $bool = json_false()

The canonical L<Cpanel::JSON::XS> boolean values, useful when building
structures destined for L</encode_json>.

=item $data = decode_json_no_null($json)

Decode C<$json> with every unescaped C<\0> / C<\u0000> sequence first
rewritten to its escaped form, so producers that emit raw nulls can
still be consumed. Dies on any underlying decode failure.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
