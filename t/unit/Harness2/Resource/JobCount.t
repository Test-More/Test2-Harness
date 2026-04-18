use Test2::V0;
use Test2::Harness2::Resource::JobCount;
use Test2::Harness2::Run::Job;
use Test2::Harness2::TestFile;

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

subtest 'is a job limiter and is applicable by default' => sub {
    my $r = Test2::Harness2::Resource::JobCount->new(slots => 1);
    ok($r->is_job_limiter, 'is_job_limiter');
    ok($r->applicable,     'applicable by default');
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

subtest 'broken state disables availability' => sub {
    my $r = Test2::Harness2::Resource::JobCount->new(slots => 2);
    $r->mark_broken;
    is($r->available(id => 'x', job => make_job()), 0, 'broken resource unavailable');
    $r->mark_resumed;
    ok($r->is_usable, 'usable after resume');
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

done_testing;
