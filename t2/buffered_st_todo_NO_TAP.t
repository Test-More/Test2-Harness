use Test2::Bundle::Extended;

subtest wrapper => sub {
    my $todo = todo("test todo");
    subtest todo => sub {
        ok(0, "fail");
    };
};

done_testing;

