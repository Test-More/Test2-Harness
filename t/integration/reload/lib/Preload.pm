package Preload;
use strict;
use warnings;

use Test2::Harness::Runner::Preload;

print "$$ $0 - Loaded ${ \__PACKAGE__ }\n";

stage A => sub {
    default();

    # Anon sub
    preload sub {
        *Preload::A::PreDefined          = sub { 'yes' };
        *Preload::WarningA::PreDefined   = sub { 'yes' };
        *Preload::ExceptionA::PreDefined = sub { 'yes' };
        *Preload::ExporterA::PreDefined  = sub { 'yes' };
    };

    preload 'Preload::A';
    preload 'Preload::WarningA';
    preload 'Preload::ExceptionA';
    preload 'Preload::ExporterA';
};

sub yes { 'yes' }

stage B => sub {
    preload sub {
        # Not an anon sub
        *Preload::A::PreDefined          = \&yes;
        *Preload::WarningA::PreDefined   = \&yes;
        *Preload::ExceptionA::PreDefined = \&yes;
        *Preload::ExporterA::PreDefined  = \&yes;

        *Preload::B::PreDefined          = \&yes;
        *Preload::WarningB::PreDefined   = \&yes;
        *Preload::ExceptionB::PreDefined = \&yes;
        *Preload::ExporterB::PreDefined  = \&yes;

        *Preload::IncChange::PreDefined = \&yes;
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
