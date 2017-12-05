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

    my $slot = $one->get_slot();
    is($slot, [[1 => T()]], "Got back the slot number and a file descriptor");

    ok(!$one->get_slot(),       "Cannot get the slot again, it is locked");
    ok(!$one->get_immiscible(), "Cannot get immiscible while a slot is locked");
    ok(!$one->get_isolation(),  "Cannot get isolation while a slot is locked");

    $slot = undef;
    ok($one->get_slot(), "Can get slot again after freeing the old ref");

    my $lock;
    is(
        $lock = $one->get_immiscible(),
        [
            [1            => T()],
            ['immiscible' => T()],
        ],
        "Got immiscible lock and slot"
    );

    ok(!$one->get_slot(), "Cannot get the slot again, it is locked");
    $lock = undef;

    is(
        $lock = $one->get_isolation(),
        [
            ['isolation' => T()],
            [1           => T()],
        ],
        "Got isolation lock and slot"
    );

    ok(!$one->get_slot, "Cannot get the slot again, it is locked");
    $lock = undef;
};

subtest two_slots => sub {
    my $DIR = tempdir(CLEANUP => 1);
    my $one = $CLASS->new(dir => $DIR, slots => 2);
    isa_ok($one, [$CLASS], "Created an instance");

    my $slot1 = $one->get_slot();
    is($slot1, [[1 => T()]], "Got back the slot number and a file descriptor");

    my $slot2 = $one->get_slot();
    is($slot2, [[2 => T()]], "Got back the slot number and a file descriptor");

    ok(!$one->get_slot(),       "Cannot get a slot, all locked");
    ok(!$one->get_immiscible(), "Cannot get immiscible while slots are all locked");
    ok(!$one->get_isolation(),  "Cannot get isolation while slots are all locked");

    $slot1 = undef;
    ok($one->get_slot(), "Can get slot again after freeing the old ref");

    my $lock;
    is(
        $lock = $one->get_immiscible(),
        [
            [1            => T()],
            ['immiscible' => T()],
        ],
        "Got immiscible lock and a slot"
    );

    $slot2 = undef;
    ok($one->get_slot(),        "There is a free slot");
    ok(!$one->get_immiscible(), "Cannot get immiscible while there is another immiscible");
    $lock = undef;

    $slot1 = $one->get_slot();
    ok($one->get_slot(),       "There is a free slot");
    ok(!$one->get_isolation(), "Cannot get isolation while any slot is locked");
    $slot1 = undef;

    is(
        $lock = $one->get_isolation(),
        [
            ['isolation' => T()],
            [1           => T()],
            [2           => T()],
        ],
        "Got isolation lock and both slots"
    );

    ok(!$one->get_slot(), "Cannot get the slot again, it is locked");
    $lock = undef;
};

subtest five_slots => sub {
    my $DIR = tempdir(CLEANUP => 1);
    my $one = $CLASS->new(dir => $DIR, slots => 5);
    isa_ok($one, [$CLASS], "Created an instance");

    my $cnt = 1;
    my @slots;
    while (my $slot = $one->get_slot()) {
        push @slots => $slot;
        is($slot, [[$cnt++ => T()]], "Got back the slot number and a file descriptor");
    }

    ok(!$one->get_immiscible(), "Cannot get immiscible while slots are all locked");
    ok(!$one->get_isolation(),  "Cannot get isolation while slots are all locked");

    @slots = ($slots[-1]);

    my $lock;
    is(
        $lock = $one->get_immiscible(),
        [
            [1            => T()],
            ['immiscible' => T()],
        ],
        "Got immiscible lock and a slot"
    );

    @slots = ();
    ok($one->get_slot(),        "There is a free slot");
    ok(!$one->get_immiscible(), "Cannot get immiscible while there is another immiscible");
    $lock = undef;

    my $slot1 = $one->get_slot();
    ok($one->get_slot(),       "There is a free slot");
    ok(!$one->get_isolation(), "Cannot get isolation while any slot is locked");
    $slot1 = undef;

    is(
        $lock = $one->get_isolation(),
        [
            ['isolation' => T()],
            [1           => T()],
            [2           => T()],
            [3           => T()],
            [4           => T()],
            [5           => T()],
        ],
        "Got isolation lock and all slots"
    );

    ok(!$one->get_slot(), "Cannot get the slot again, it is locked");
    $lock = undef;
};

done_testing;
