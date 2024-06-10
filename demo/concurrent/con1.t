use Test2::V0;

subtest a => sub {
    ok(1, "start");
    sleep 4;
    ok(1, "end");
};

subtest b => sub {
    ok(1, "start");
    sleep 4;
    ok(1, "end");
};

subtest c => sub {
    ok(1, "start");
    sleep 4;
    ok(1, "end");
};

subtest d => sub {
    ok(1, "start");
    sleep 4;
    ok(1, "end");
};

subtest e => sub {
    ok(1, "start");
    sleep 4;
    ok(1, "end");
};

done_testing;
