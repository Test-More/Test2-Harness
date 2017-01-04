package Test2::Harness::JSON;
use strict;
use warnings;

our $VERSION = '0.000014';

BEGIN {
    local $@ = undef;
    my $ok = eval {
        require JSON::MaybeXS;
        JSON::MaybeXS->import('JSON');
        1;
    };

    unless($ok) {
        require JSON::PP;
        *JSON = sub() { 'JSON::PP' };
    }
}

our @EXPORT = qw{JSON};
BEGIN { require Exporter; our @ISA = qw(Exporter) }

1;
