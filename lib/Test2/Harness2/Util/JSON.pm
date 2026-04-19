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
    encode_json
    encode_json_file
    encode_pretty_json
    json_false
    json_true
    stream_json_l
    stream_json_l_file
    stream_json_l_url
    write_json_file_atomic
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

# Iterate a path or URL of JSON / JSONL records, calling $handler for
# each decoded entry. Local files are dispatched to stream_json_l_file;
# http(s) URLs to stream_json_l_url. A whole-file .json is treated as a
# single top-level record; a .jsonl file as one record per line. Both
# forms accept optional .gz / .bz2 compression through
# Test2::Harness2::Util::open_file.
sub stream_json_l {
    my ($path, $handler, %params) = @_;

    croak "No path provided" unless $path;

    return stream_json_l_file($path, $handler) if -f $path;
    return stream_json_l_url($path, $handler, %params) if $path =~ m{^https?://};

    croak "'$path' is not a valid path (file does not exist, or is not an http(s) url)";
}

sub stream_json_l_file {
    my ($path, $handler) = @_;

    croak "Invalid file '$path'" unless -f $path;

    croak "Path must have a .json or .jsonl extension with optional .gz or .bz2 postfix."
        unless $path =~ m/\.(json(?:l)?)(?:.(?:bz2|gz))?$/;

    if ($1 eq 'json') {
        require Test2::Harness2::Util::File::JSON;
        my $json = Test2::Harness2::Util::File::JSON->new(name => $path);
        $handler->($json->read);
    }
    else {
        require Test2::Harness2::Util::File::JSONL;
        my $jsonl = Test2::Harness2::Util::File::JSONL->new(name => $path);
        while (my ($item) = $jsonl->poll(max => 1)) {
            $handler->($item);
        }
    }

    return 1;
}

# Stream a JSONL response: each newline-terminated chunk becomes one
# call to $handler. %params are forwarded to HTTP::Tiny; set
# http_method (default 'get') to change the verb, and http_args to
# pass extra hash-ref options alongside data_callback. Returns whatever
# HTTP::Tiny's response hash would normally return.
sub stream_json_l_url {
    my ($path, $handler, %params) = @_;
    my $meth = $params{http_method} // 'get';
    my $args = $params{http_args}   // [];

    require HTTP::Tiny;
    my $ht = HTTP::Tiny->new();

    my $buffer  = '';
    my $iterate = sub {
        my ($res) = @_;

        my @parts = split /(\n)/, $buffer;

        while (@parts > 1) {
            my $line = shift @parts;
            my $nl   = shift @parts;
            my $data;
            unless (eval { $data = decode_json($line); 1 }) {
                warn "Unable to decode json for chunk when parsing json/l chunk:\n----\n$line\n----\n$@\n----\n";
                next;
            }

            $handler->($data, $res);
        }

        $buffer = shift @parts // '';
    };

    my $res = $ht->$meth(
        $path,
        {
            @$args,
            data_callback => sub {
                my ($chunk, $res) = @_;
                $buffer .= $chunk;
                $iterate->($res);
            },
        }
    );

    if (length($buffer)) {
        $buffer .= "\n" unless $buffer =~ m/\n$/;
        $iterate->($res);
    }

    return $res;
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

=item stream_json_l($path_or_url, $handler, %params)

Iterate a local C<.json> / C<.jsonl> file (with optional C<.gz> /
C<.bz2> postfix) or an C<http(s)://> URL, calling
C<< $handler->($decoded) >> for each record. Local files dispatch to
L</stream_json_l_file>; URLs dispatch to L</stream_json_l_url>.

=item stream_json_l_file($path, $handler)

Stream a local file. C<.json> is treated as one whole-document record
(handler called once); C<.jsonl> as one record per line.

=item $res = stream_json_l_url($url, $handler, %params)

Stream an HTTP(S) response body as JSONL. C<%params> are forwarded to
L<HTTP::Tiny>:

=over 4

=item C<http_method> — defaults to C<'get'>.

=item C<http_args> — extra arrayref of options merged into the request
hash.

=back

Returns whatever L<HTTP::Tiny> returns.

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
