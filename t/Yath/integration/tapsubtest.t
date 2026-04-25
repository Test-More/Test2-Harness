# HARNESS-CONFLICTS YATH
use Test2::V0;

use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;
my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-j1', '-v'],
    exit    => 0,
    test    => sub {
        my $out = shift;

        my @lines = split /\n/, $out->{output};

        like(
            \@lines,
            subset {
                item '[  PASS  ]  job 1 +~buffered';
                item '[  PASS  ]  job 1   +~nested';
                item '[  PASS  ]  job 1   | + buffered ok';
                item '[  PLAN  ]  job 1   | | Expected assertions: 1';
                item '            job 1   | ^';
                item '[  PLAN  ]  job 1   | Expected assertions: 1';
                item '            job 1   ^';
                item '[  PLAN  ]  job 1   Expected assertions: 1';
            },
            "Got the desired output"
        );
    },
);

done_testing;
