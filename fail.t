use Test2::V0;
ok(1);
sleep 4;
ok(0, "oops");
sleep 4;
ok(1);
sleep 4;
done_testing;
