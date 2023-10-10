use strict;
use warnings;

our $VERSION = '0.000144';

use Test2::Harness::UI::Config;
use Test2::Harness::UI::Dumper;

if (grep { m/^-+(h(?:elp)?|\?)$/ } @ARGV) {
    print "Usage: $0 outputfile 'DSN' ['USER'] ['PASSWORD']\nDSN is required, sql username and password are optional.\n";
    exit 0;
}

my $dsn = shift @ARGV // die "Must provide a DSN as the first command line argument";

my ($user, $pass) = @ARGV;

my $config = Test2::Harness::UI::Config->new(
    dbi_dsn     => $dsn,
    dbi_user    => $user // '',
    dbi_pass    => $pass // '',
    single_user => 1,
    show_user   => 0,
);

my $dumper = Test2::Harness::UI::Dumper->new(
    config => $config,
    procs => $ENV{DUMP_PROCS} // 1,
);

$dumper->dump();
