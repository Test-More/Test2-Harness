package Preload;
use strict;
use warnings;

use Test2::Harness::Preload;

print "$$ $0 - Loaded ${ \__PACKAGE__ }\n";

my $path = __FILE__;
$path =~ s{\.pm$}{};

stage A => sub {
    default();

    watch "$path/nonperl1" => sub { print STDERR "$$ $0 - RELOAD CALLBACK nonperl1\n" };

    preload sub {
        watch "$path/nonperl2" => sub { print STDERR "$$ $0 - RELOAD CALLBACK nonperl2\n" };
    };

    preload 'Preload::A';
    preload 'Preload::WarningA';
    preload 'Preload::ExceptionA';
    preload 'Preload::ExporterA';
    preload 'Preload::Churn';
};

stage B => sub {
    reload_inplace_check sub {
        my %params = @_;

        print STDERR "$$ $0 - INPLACE CHECK CALLED: $params{file} - $params{module}\n"
            if $params{module} eq 'Preload::A';

        return;
    };

    preload sub {
        no warnings 'once';
        *Preload::X::PreDefined = sub { 'yes' };
    };

    preload 'Preload::A';
    preload 'Preload::WarningA';
    preload 'Preload::ExceptionA';
    preload 'Preload::ExporterA';

    preload 'Preload::B';
    preload 'Preload::WarningB';
    preload 'Preload::ExceptionB';
    preload 'Preload::ExporterB';

    preload 'Preload::IncChange';
};

1;
