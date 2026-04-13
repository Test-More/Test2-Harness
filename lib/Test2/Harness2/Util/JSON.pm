package Test2::Harness2::Util::JSON;
use strict;
use warnings;

use Carp qw/confess croak/;
use Cpanel::JSON::XS();
use File::Temp qw/tempfile/;
use Importer Importer => 'import';

our $VERSION = '2.000011';

our @EXPORT_OK = qw{
    decode_json
    encode_json
    encode_pretty_json
    decode_json_file
    encode_json_file
    json_true
    json_false
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

sub json_true  { Cpanel::JSON::XS->true }
sub json_false { Cpanel::JSON::XS->false }

1;
