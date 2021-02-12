use strict;
use warnings;

use Test2::V0;
use Test2::Tools::Subtest qw/subtest_streamed/;
use Test2::Harness::Util::JSON qw/encode_pretty_json/;

my @want = map {
    ("a" x 1024) . "\n",
        ("b" x 1024) . "\n",
        ("c" x 1024) . "\n",
        ("d" x 1024) . "\n",
        ("e" x 1024) . "\n",
} 1 .. 512;

my $closed = 0;
for (1 .. 100_000) {
    if (my $want = shift @want) {
        is(<STDIN>, $want, "Got a line from STDIN");
    }
    elsif(!$closed++) {
        close(STDIN);
        ok(1, "pass $_");
    }
    else {
        ok(1, "pass $_");
    }
}

done_testing;
