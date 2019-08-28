use Test2::V0;
# HARNESS-NO-TIMEOUT

ok(1, "Now");

{
    package WAIT;

    sub DESTROY { sleep 70 }
}

my $thing = bless {}, 'WAIT';

ok(1, "Later");

done_testing;
