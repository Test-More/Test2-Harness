package Test2::Harness::Util::JSON;
use strict;
use warnings;

use Carp qw/confess longmess/;
use Cpanel::JSON::XS();
use Importer Importer => 'import';

our $VERSION = '2.000000';

our @EXPORT = qw{encode_json decode_json encode_ascii_json encode_pretty_json encode_canon_json};

my $json   = Cpanel::JSON::XS->new->utf8(1)->convert_blessed(1)->allow_nonref(1);
my $ascii  = Cpanel::JSON::XS->new->ascii(1)->convert_blessed(1)->allow_nonref(1);
my $canon  = Cpanel::JSON::XS->new->utf8(1)->canonical(1)->convert_blessed(1)->allow_nonref(1);
my $pretty = Cpanel::JSON::XS->new->utf8(1)->pretty(1)->canonical(1)->convert_blessed(1)->allow_nonref(1);

sub decode_json        { my $out; eval { $out = $json->decode(@_);   1} // confess($@); $out }
sub encode_json        { my $out; eval { $out = $json->encode(@_);   1} // confess($@); $out }
sub encode_ascii_json  { my $out; eval { $out = $ascii->encode(@_);  1} // confess($@); $out }
sub encode_canon_json  { my $out; eval { $out = $canon->encode(@_);  1} // confess($@); $out }
sub encode_pretty_json { my $out; eval { $out = $pretty->encode(@_); 1} // confess($@); $out }

1;
