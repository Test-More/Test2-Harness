use Test2::V0;
use v5.38;

subtest outer => sub {
    ok(1, "child a");
    note("a NOTE inside the subtest");
    diag("a DIAG inside the subtest");
    print "raw STDOUT inside subtest\n";
    ok(1, "child b");
};

done_testing;
