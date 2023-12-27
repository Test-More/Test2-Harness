package Preload;
use strict;
use warnings;

use Test2::Harness::Runner::Preload;

print "$$ $0 - Loaded ${ \__PACKAGE__ }\n";

my $path = __FILE__;
$path =~ s{\.pm$}{};
use Data::Dumper;
print Dumper($path);

stage A => sub {
    default();

    watch "$path/nonperl1" => sub { print "$$ $0 - RELOAD CALLBACK nonperl1\n" };

    preload sub {
        watch "$path/nonperl2" => sub { print "$$ $0 - RELOAD CALLBACK nonperl2\n" };
    };

    preload 'Preload::A';
    preload 'Preload::WarningA';
    preload 'Preload::ExceptionA';
    preload 'Preload::ExporterA';
    preload 'Preload::Churn';
};

stage B => sub {
    reload_remove_check sub {
        my %params = @_;
        return 1 if $params{reload_file} eq $params{from_file};
        return 0;
    };

    preload sub {
        *Preload::B::PreDefined = sub { 'yes' };
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
