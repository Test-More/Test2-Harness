use Test2::V0 -target => 'Test2::Harness::Run::Runner::ProcMan::Locker';

use ok $CLASS;

use File::Temp qw/tempdir/;

like(
    dies { $CLASS->new() },
    qr/'dir' is a required attribute/,
    "Got exception"
);

subtest one_slot => sub {
    my $DIR = tempdir(CLEANUP => 1);
    my $one = $CLASS->new(dir => $DIR);
    isa_ok($one, [$CLASS], "Created an instance");

    {
        my $slot = $one->get_lock();
        is($slot, [["slot-1" => T()]], "Got back the slot number and a file descriptor");
        ok(!$one->get_lock(), "Cannot get the slot again, it is locked");
        $slot = undef;

        ok($one->get_lock, "got the lock again");
    }

    {
        my $slot  = $one->get_lock;           # Make sure these work with a slot locked
        my $lock1 = $one->get_immiscible();
        ok($lock1,                  "got immiscible lock");
        ok(!$one->get_immiscible(), "Cannot get immiscible again");
        $lock1 = undef;
        ok($one->get_immiscible(), "Can get immiscible again once freed");

        $lock1 = $one->get_long();
        ok($lock1,            "got long lock");
        ok(!$one->get_long(), "Cannot get long again");
        $lock1 = undef;
        ok($one->get_long(), "Can get long again once freed");
    }

    my $lock1 = $one->get_isolation();
    ok($lock1, "Got isolation lock");
    like(
        $lock1,
        [["isolation-1"], ["slot-1"]],
        "Got both the isolation lock, and the slot locks"
    );

    ok(!$one->get_isolation, "Only 1 isolation at a time");

    $lock1 = undef;
    ok($one->get_isolation, "Isolation available again");

    $lock1 = $one->get_lock;
    ok(!$one->get_isolation, "No isolation if a slot is locked");
};

subtest two_slots => sub {
    my $DIR = tempdir(CLEANUP => 1);
    my $one = $CLASS->new(dir => $DIR, slots => 2);
    isa_ok($one, [$CLASS], "Created an instance");

    {
        my $slot1 = $one->get_lock();
        is($slot1, [["slot-1" => T()]], "Got back the slot number and a file descriptor");

        my $slot2 = $one->get_lock();
        is($slot2, [["slot-2" => T()]], "Got back the slot number and a file descriptor");

        ok(!$one->get_lock(), "Cannot get the slot again, it all locked");
        $slot1 = undef;

        ok($one->get_lock, "got the lock again");
    }

    {
        my $slot  = $one->get_lock;           # Make sure these work with a slot locked
        my $lock1 = $one->get_immiscible();
        ok($lock1,                  "got immiscible lock");
        ok(!$one->get_immiscible(), "Cannot get immiscible again");
        $lock1 = undef;
        ok($one->get_immiscible(), "Can get immiscible again once freed");

        $lock1 = $one->get_long();
        ok($lock1,            "got long lock");
        ok(!$one->get_long(), "Cannot get long again");
        $lock1 = undef;
        ok($one->get_long(), "Can get long again once freed");
    }

    my $lock1 = $one->get_isolation();
    ok($lock1, "Got isolation lock");
    like(
        $lock1,
        [["isolation-1"], ["slot-1"], ["slot-2"]],
        "Got both the isolation lock, and the slot locks"
    );

    ok(!$one->get_isolation, "Only 1 isolation at a time");

    $lock1 = undef;
    ok($one->get_isolation, "Isolation available again");

    $lock1 = $one->get_lock;
    ok(!$one->get_isolation, "No isolation if a slot is locked");
};

subtest five_slots => sub {
    my $DIR = tempdir(CLEANUP => 1);
    my $one = $CLASS->new(dir => $DIR, slots => 5);
    isa_ok($one, [$CLASS], "Created an instance");

    {
        my $slot1 = $one->get_lock();
        is($slot1, [["slot-1" => T()]], "Got back the slot number and a file descriptor");

        my $slot2 = $one->get_lock();
        is($slot2, [["slot-2" => T()]], "Got back the slot number and a file descriptor");

        my $slot3 = $one->get_lock();
        is($slot3, [["slot-3" => T()]], "Got back the slot number and a file descriptor");

        my $slot4 = $one->get_lock();
        is($slot4, [["slot-4" => T()]], "Got back the slot number and a file descriptor");

        my $slot5 = $one->get_lock();
        is($slot5, [["slot-5" => T()]], "Got back the slot number and a file descriptor");

        ok(!$one->get_lock(), "Cannot get the slot again, it all locked");
        $slot1 = undef;

        ok($one->get_lock, "got the lock again");
    }

    {
        my $slot  = $one->get_lock;           # Make sure these work with a slot locked
        my $lock1 = $one->get_immiscible();
        ok($lock1,                  "got immiscible lock");
        ok(!$one->get_immiscible(), "Cannot get immiscible again");
        $lock1 = undef;
        ok($one->get_immiscible(), "Can get immiscible again once freed");

        $lock1 = $one->get_long();
        ok($lock1,            "got long lock");

        my $lock2 = $one->get_long();
        ok($lock2,            "got long lock");

        my $lock3 = $one->get_long();
        ok($lock3,            "got long lock");

        my $lock4 = $one->get_long();
        ok($lock4,            "got long lock");

        ok(!$one->get_long(), "Cannot get long again");
        $lock1 = undef;
        ok($one->get_long(), "Can get long again once freed");
    }

    my $lock1 = $one->get_isolation();
    ok($lock1, "Got isolation lock");
    like(
        $lock1,
        [["isolation-1"], ["slot-1"], ["slot-2"], ["slot-3"], ["slot-4"], ["slot-5"]],
        "Got both the isolation lock, and the slot locks"
    );

    ok(!$one->get_isolation, "Only 1 isolation at a time");

    $lock1 = undef;
    ok($one->get_isolation, "Isolation available again");

    $lock1 = $one->get_lock;
    ok(!$one->get_isolation, "No isolation if a slot is locked");
};

done_testing;
