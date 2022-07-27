use strict;
use warnings;

our $VERSION = '0.000125';

use Test2::Harness::UI::Config;
use Test2::Harness::UI::BackFill;

if (grep { m/^-+(h(?:elp)?|\?)$/ } @ARGV) {
    print "Usage: $0 'DSN' 'METHOD' ['USER'] ['PASSWORD']\nDSN is required, sql username and password are optional.\n";
    exit 0;
}

my $dsn = shift @ARGV // die "Must provide a DSN as the first command line argument";

my ($meth, $user, $pass) = @ARGV;

my $config = Test2::Harness::UI::Config->new(
    dbi_dsn     => $dsn,
    dbi_user    => $user // '',
    dbi_pass    => $pass // '',
    single_user => 1,
    show_user   => 0,
);

my $backfill = Test2::Harness::UI::BackFill->new(config => $config);
$backfill->$meth();
