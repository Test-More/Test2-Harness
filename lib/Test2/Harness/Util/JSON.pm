package Test2::Harness::Util::JSON;
use strict;
use warnings;

use Carp qw/confess longmess croak/;
use Cpanel::JSON::XS();
use Importer Importer => 'import';

our $VERSION = '2.000000';

our @EXPORT_OK = qw{
    decode_json
    encode_json
    encode_ascii_json
    encode_pretty_json
    encode_canon_json
    stream_json_l
    stream_json_l_url
    stream_json_l_file

    json_true
    json_false
};

my $json   = Cpanel::JSON::XS->new->utf8(1)->convert_blessed(1)->allow_nonref(1);
my $ascii  = Cpanel::JSON::XS->new->ascii(1)->convert_blessed(1)->allow_nonref(1);
my $canon  = Cpanel::JSON::XS->new->utf8(1)->canonical(1)->convert_blessed(1)->allow_nonref(1);
my $pretty = Cpanel::JSON::XS->new->utf8(1)->pretty(1)->canonical(1)->convert_blessed(1)->allow_nonref(1);

sub decode_json        { my $out; eval { $out = $json->decode(@_);   1} // confess($@); $out }
sub encode_json        { my $out; eval { $out = $json->encode(@_);   1} // confess($@); $out }
sub encode_ascii_json  { my $out; eval { $out = $ascii->encode(@_);  1} // confess($@); $out }
sub encode_canon_json  { my $out; eval { $out = $canon->encode(@_);  1} // confess($@); $out }
sub encode_pretty_json { my $out; eval { $out = $pretty->encode(@_); 1} // confess($@); $out }

sub json_true  { Cpanel::JSON::XS->true }
sub json_false { Cpanel::JSON::XS->false }

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
        require Test2::Harness::Util::File::JSON;
        my $json = Test2::Harness::Util::File::JSON->new(name => $path);
        $handler->($json->read);
    }
    else {
        require Test2::Harness::Util::File::JSONL;
        my $jsonl = Test2::Harness::Util::File::JSONL->new(name => $path);
        while (my ($item) = $jsonl->poll(max => 1)) {
            $handler->($item);
        }
    }

    return 1;
}

sub stream_json_l_url {
    my ($path, $handler, %params) = @_;
    my $meth = $params{http_method} // 'get';
    my $args = $params{http_args} // [];

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
