package Test2::Harness2::Util;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak confess/;
use Importer Importer => 'import';

our @EXPORT_OK = qw{
    mod2file
    parse_exit
};

sub mod2file {
    my ($mod) = @_;
    confess "No module name provided" unless $mod;
    my $file = $mod;
    $file =~ s{::}{/}g;
    $file .= ".pm";
    return $file;
}

sub parse_exit {
    my ($exit) = @_;
    croak "an exit value is required" unless defined $exit;

    my $sig = $exit & 127;
    my $dmp = $exit & 128;

    return {
        sig => $sig,
        err => ($exit >> 8),
        dmp => $dmp,
        all => $exit,
    };
}

1;
