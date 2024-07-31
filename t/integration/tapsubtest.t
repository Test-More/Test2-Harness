use Test2::V0;

use App::Yath::Tester qw/yath/;
use Test2::Plugin::Immiscible(sub { $ENV{TEST2_HARNESS_ACTIVE} ? 1 : 0 });


my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-v'],
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
