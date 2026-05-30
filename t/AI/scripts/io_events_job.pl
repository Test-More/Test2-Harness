use Test2::V0;
use v5.38;

subtest outer => sub {
    ok(1, "A");
    print STDOUT "inside-stdout\n";
    print STDERR "inside-stderr\n";
    warn "inside-warn\n";
    ok(1, "B");
};

print STDOUT "top-stdout\n";

done_testing;
