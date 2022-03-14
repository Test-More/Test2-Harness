use strict;
use warnings;

our $VERSION = '0.000117';

use Test2::Harness::UI::Config;
use Test2::Harness::UI::Sweeper;

if (grep { m/^-+(h(?:elp)?|\?)$/ } @ARGV) {
    print "Usage: $0 'DSN' ['USER'] ['PASSWORD'] 'INTERVAL'\nDSN and Interval are required, sql username and password are optional.\n";
    exit 0;
}

my $dsn      = shift @ARGV // die "Must provide a DSN as the first command line argument";
my $interval = pop @ARGV   // die "Must provide an sql interval value (Example: '2 day') as the final command line argument";

my ($user, $pass) = @ARGV;

$interval //= "10 day";

my $config = Test2::Harness::UI::Config->new(
    dbi_dsn     => $dsn,
    dbi_user    => $user // '',
    dbi_pass    => $pass // '',
    single_user => 1,
    show_user   => 0,
);

my $sweeper = Test2::Harness::UI::Sweeper->new(
    config   => $config,
    interval => $interval,
);

$sweeper->sweep(coverage => 0);
