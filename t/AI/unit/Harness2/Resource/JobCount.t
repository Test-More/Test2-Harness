use Test2::V0;

use lib 't/lib';
use Test2::Harness2::TestFile;

use Test2::Harness2::Resource::JobCount;
use Test2::Harness2::Run::Job;

sub make_job {
    my (%tf_attrs) = @_;
    my $tf = Test2::Harness2::TestFile->new(file => 't/x.t', %tf_attrs);
    return Test2::Harness2::Run::Job->new(
        test_file => $tf,
        run_id    => 'r',
    );
}

subtest 'requires a positive slot count' => sub {
    my $ok = eval { Test2::Harness2::Resource::JobCount->new; 1 };
    ok(!$ok, 'no slots attr -> dies');

    $ok = eval { Test2::Harness2::Resource::JobCount->new(slots => 0); 1 };
    ok(!$ok, 'zero slots -> dies');

    $ok = eval { Test2::Harness2::Resource::JobCount->new(slots => -1); 1 };
    ok(!$ok, 'negative slots -> dies');

    my $r = Test2::Harness2::Resource::JobCount->new(slots => 4);
    is($r->slots, 4);
    is($r->used,  0);
};

subtest 'is needed by default' => sub {
    my $r = Test2::Harness2::Resource::JobCount->new(slots => 1);
    ok($r->needed, 'needed by default');
    is($r->resource_name, 'jobcount');
};

subtest 'available gates on free slots' => sub {
    my $r = Test2::Harness2::Resource::JobCount->new(slots => 2);
    my $j = make_job();
    is($r->available(id => 'a', job => $j), 1, 'one slot free -> 1');

    my %env;
    is($r->assign(id => 'a', job => $j, env => \%env), 1, 'assigned 1');
    is($env{T2_HARNESS_MY_JOB_CONCURRENCY},            1, 'env var populated');
    is($r->used,                                       1, 'used bumped');

    is($r->available(id => 'b', job => make_job()), 1, 'one free still');
    $r->assign(id => 'b', job => make_job(), env => {});
    is($r->used, 2);

    is($r->available(id => 'c', job => make_job()), 0, 'full -> 0');

    $r->release(id => 'a');
    is($r->used,                                    1, 'released back');
    is($r->available(id => 'c', job => make_job()), 1, 'free again');
};

subtest 'min_slots larger than pool -> -1 (skip)' => sub {
    my $r = Test2::Harness2::Resource::JobCount->new(slots => 2);
    my $j = make_job(min_slots => 4);
    is($r->available(id => 'x', job => $j), -1, 'unsatisfiable');
};

subtest 'max_slots > min_slots grants up to max' => sub {
    my $r   = Test2::Harness2::Resource::JobCount->new(slots => 4);
    my $j   = make_job(min_slots => 2, max_slots => 3);
    my $got = $r->available(id => 'p', job => $j);
    is($got, 3, 'granted max when free allows');
};

subtest 'max_slots <= 0 means "as many as free"' => sub {
    my $r = Test2::Harness2::Resource::JobCount->new(slots => 5);
    my $j = make_job(min_slots => 1, max_slots => 0);
    is($r->available(id => 'p', job => $j), 5, 'grants all free');
};

subtest 'status reflects current state' => sub {
    my $r = Test2::Harness2::Resource::JobCount->new(slots => 3);
    my $j = make_job();
    $r->assign(id => 's1', job => $j, env => {});
    my $s = $r->status;
    is($s->{resource},              'jobcount');
    is($s->{slots},                 3);
    is($s->{used},                  1);
    is($s->{free},                  2);
    is(scalar @{$s->{assignments}}, 1, 'one assignment tracked');
    is($s->{assignments}[0]{id},    's1');
    is($s->{assignments}[0]{count}, 1);
};

subtest 'JobCount supports paused state but not broken' => sub {
    # available() no longer self-gates on broken/paused state -- the
    # scheduler checks is_usable first. JobCount has no backing
    # service, so broken transitions are not supported: the role's
    # croaking defaults apply. Pausing is supported.
    my $r = Test2::Harness2::Resource::JobCount->new(slots => 2);
    ok($r->is_usable, 'usable when healthy');

    like(
        dies { $r->mark_broken },
        qr/mark_broken is not implemented/,
        'JobCount cannot be marked broken',
    );
    like(
        dies { $r->mark_permanent_broken },
        qr/mark_permanent_broken is not implemented/,
        'JobCount cannot be marked permanent_broken',
    );
    is($r->is_broken,           0, 'is_broken stays 0');
    is($r->is_permanent_broken, 0, 'is_permanent_broken stays 0');

    $r->mark_paused;
    ok($r->is_paused,  'paused after mark_paused');
    ok(!$r->is_usable, 'not usable when paused');
    $r->mark_resumed;
    ok(!$r->is_paused, 'resumed after mark_resumed');
    ok($r->is_usable,  'usable after resume');
};

subtest 'duplicate assign id rejected' => sub {
    my $r = Test2::Harness2::Resource::JobCount->new(slots => 2);
    $r->assign(id => 'dup', job => make_job(), env => {});
    my $ok = eval { $r->assign(id => 'dup', job => make_job(), env => {}); 1 };
    ok(!$ok, 'croaks on duplicate id');
};

subtest 'release of unknown id rejected' => sub {
    my $r  = Test2::Harness2::Resource::JobCount->new(slots => 2);
    my $ok = eval { $r->release(id => 'nope'); 1 };
    ok(!$ok, 'croaks on unknown release id');
};

subtest 'max_per_job validation' => sub {
    my $ok = eval { Test2::Harness2::Resource::JobCount->new(slots => 4, max_per_job => 0); 1 };
    ok(!$ok, 'max_per_job=0 rejected');

    $ok = eval { Test2::Harness2::Resource::JobCount->new(slots => 4, max_per_job => -1); 1 };
    ok(!$ok, 'max_per_job=-1 rejected');

    $ok = eval { Test2::Harness2::Resource::JobCount->new(slots => 4, max_per_job => 8); 1 };
    ok(!$ok, 'max_per_job > slots rejected');

    my $r = Test2::Harness2::Resource::JobCount->new(slots => 4, max_per_job => 2);
    is($r->max_per_job, 2, 'max_per_job stored');
};

subtest 'max_per_job clamps test max_slots downward' => sub {
    my $r = Test2::Harness2::Resource::JobCount->new(slots => 16, max_per_job => 8);

    # Test asks for fixed 1 slot -> still gets 1 (no clamp needed).
    my $j1 = make_job(min_slots => 1, max_slots => 1);
    is($r->available(id => 'a', job => $j1), 1, 'fixed-1 test gets 1');

    # Test asks for fixed 4 slots -> gets 4 (under cap).
    my $j4 = make_job(min_slots => 4, max_slots => 4);
    is($r->available(id => 'b', job => $j4), 4, 'fixed-4 test gets 4');

    # Test asks for fixed 16 slots -> clamped to 8 by max_per_job.
    my $j16 = make_job(min_slots => 1, max_slots => 16);
    is($r->available(id => 'c', job => $j16), 8, 'wide range clamped to max_per_job');

    # Test asks for max_slots = 0 ("as many as free") -> still capped at 8.
    my $jmax = make_job(min_slots => 1, max_slots => 0);
    is($r->available(id => 'd', job => $jmax), 8, '"as many as free" capped at max_per_job');
};

subtest 'HARNESS-JOB-SLOTS MIN MAX range honoured under cap' => sub {
    # Range form: test asks for between MIN and MAX slots, takes
    # whatever is free in that window. The per-job cap clamps the
    # MAX side; the MIN side still gates whether the test can run
    # at all.
    my $r = Test2::Harness2::Resource::JobCount->new(slots => 16, max_per_job => 6);

    # range 2..8: free=16, cap=6 -> grant=6 (capped down from 8).
    my $jw = make_job(min_slots => 2, max_slots => 8);
    is($r->available(id => 'a', job => $jw), 6, 'range 2..8 with cap 6 -> grant 6');

    # range 2..4: free=16, cap=6 -> grant=4 (max wins, no cap needed).
    my $jm = make_job(min_slots => 2, max_slots => 4);
    is($r->available(id => 'b', job => $jm), 4, 'range 2..4 -> grant 4');

    # range 2..0 ("as many as free"): cap substitutes -> grant=6.
    my $jo = make_job(min_slots => 2, max_slots => 0);
    is($r->available(id => 'c', job => $jo), 6, 'range 2..unbounded clamped at cap');
};

subtest 'HARNESS-JOB-SLOTS MIN MAX with MIN > cap is unsatisfiable' => sub {
    my $r = Test2::Harness2::Resource::JobCount->new(slots => 16, max_per_job => 4);
    my $j = make_job(min_slots => 8, max_slots => 16);
    is($r->available(id => 'x', job => $j), -1, 'range 8..16 with cap 4 -> -1 (MIN exceeds cap)');
};

subtest 'HARNESS-JOB-SLOTS MIN MAX adapts to free slots within range' => sub {
    # No cap; verify range-vs-free math still works as legacy.
    my $r = Test2::Harness2::Resource::JobCount->new(slots => 8);
    $r->assign(id => 'pre', job => make_job(), env => {});    # used = 1, free = 7

    # range 2..16: free=7 -> grant = min(max=16, free=7) = 7.
    my $j = make_job(min_slots => 2, max_slots => 16);
    is($r->available(id => 'a', job => $j), 7, 'range 2..16 with 7 free -> grant 7');
};

subtest 'max_per_job < min_slots reports unsatisfiable for that test only' => sub {
    my $r = Test2::Harness2::Resource::JobCount->new(slots => 16, max_per_job => 4);

    my $jbad = make_job(min_slots => 8, max_slots => 8);
    is($r->available(id => 'x', job => $jbad), -1, 'test exceeding cap is unsatisfiable');

    # The resource itself is not broken: a normal test still gets a slot.
    my $jok = make_job(min_slots => 1, max_slots => 1);
    is($r->available(id => 'y', job => $jok), 1, 'other tests still work');
};

subtest '-j 16:8 scenario: 16 default tests run concurrently' => sub {
    # Default test (no min_slots/max_slots header) consumes 1 slot each.
    # With 16-slot pool we should fit all 16 simultaneously.
    my $r = Test2::Harness2::Resource::JobCount->new(slots => 16, max_per_job => 8);
    for my $i (1 .. 16) {
        my $g = $r->available(id => "j$i", job => make_job());
        is($g, 1, "job $i grant=1");
        $r->assign(id => "j$i", job => make_job(), env => {});
    }
    is($r->used,                              16, 'pool full');
    is($r->available(id => '17', job => make_job()), 0, '17th waits');
};

subtest '-j 16:8 scenario: one 4-slot test reduces concurrency to 13' => sub {
    my $r   = Test2::Harness2::Resource::JobCount->new(slots => 16, max_per_job => 8);
    my $jw  = make_job(min_slots => 4, max_slots => 4);
    is($r->available(id => 'wide', job => $jw), 4, 'wide test grants 4');
    $r->assign(id => 'wide', job => $jw, env => {});

    # 12 of the remaining 12 default tests fit; the 13th does not.
    for my $i (1 .. 12) {
        $r->assign(id => "n$i", job => make_job(), env => {});
    }
    is($r->used, 16, 'pool full at 4 + 12');
    is($r->available(id => 'extra', job => make_job()), 0, '13th 1-slot test must wait');
};

done_testing;
