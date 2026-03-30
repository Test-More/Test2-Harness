use Test2::V0 -target => 'Test2::Harness::Resource::JobCount';

# Fake test file and job objects used throughout
{
    package FakeTestFile;
    sub check_min_slots { 1 }
    sub check_max_slots { undef }
    sub relative        { 'fake/test.t' }
}

{
    package FakeJob;
    sub test_file { bless {}, 'FakeTestFile' }
}

my $fake_job = bless {}, 'FakeJob';

# Suppress send_data_event so we don't need a live collector
{
    no warnings 'redefine';
    *Test2::Harness::Resource::JobCount::send_data_event = sub { };
}

subtest constructor_requires_slots => sub {
    like(
        dies { CLASS->new(job_slots => 4) },
        qr/slots/,
        "slots is required"
    );

    like(
        dies { CLASS->new(slots => 4) },
        qr/job_slots/,
        "job_slots is required"
    );
};

subtest construction => sub {
    my $r = CLASS->new(slots => 4, job_slots => 4);
    ok($r, "constructed");
    is($r->slots,    4, "slots accessor");
    is($r->job_slots, 4, "job_slots accessor");
    is($r->used,     0, "used starts at 0");
    is(ref($r->assignments), 'HASH', "assignments is a hashref");
};

subtest is_job_limiter => sub {
    ok(CLASS->is_job_limiter, "is_job_limiter returns true");
};

subtest applicable => sub {
    my $r = CLASS->new(slots => 4, job_slots => 4);
    ok($r->applicable('any_id', $fake_job), "always applicable");
};

subtest available => sub {
    my $r = CLASS->new(slots => 4, job_slots => 4);

    my $av = $r->available('id1', $fake_job);
    ok($av > 0, "slots are available when nothing is used");
    # check_max_slots returns undef, so max_slots defaults to min_slots (1),
    # and available returns min(max_slots, free) = min(1, 4) = 1
    is($av, 1, "available respects max_slots derived from min_slots");
};

subtest available_none_when_full => sub {
    my $r = CLASS->new(slots => 2, job_slots => 4);
    $r->{used} = 2;  # fill all slots manually

    my $av = $r->available('id1', $fake_job);
    is($av, 0, "no slots available when full");
};

subtest available_returns_negative_when_insufficient_job_slots => sub {
    # When job_slots < min_slots (1), available returns -1.
    # job_slots must be >= 1 to construct; use job_slots=1 then lower it.
    my $r = CLASS->new(slots => 4, job_slots => 1);

    # Temporarily set job_slots lower than min_slots to simulate the condition
    # We need job_slots < 1 — set it on the object directly
    {
        package FakeTestFileLarge;
        sub check_min_slots { 5 }   # requires 5 slots
        sub check_max_slots { undef }
        sub relative        { 'fake/large.t' }
    }
    {
        package FakeJobLarge;
        sub test_file { bless {}, 'FakeTestFileLarge' }
    }
    my $large_job = bless {}, 'FakeJobLarge';

    # job_slots (1) < min_slots (5) so available returns -1
    my $av = $r->available('id1', $large_job);
    is($av, -1, "returns -1 when job_slots is below min_slots");
};

subtest assign_and_release => sub {
    my $r = CLASS->new(slots => 4, job_slots => 4);

    my $env = {};
    $r->assign('job_abc', $fake_job, $env);

    ok($r->used > 0, "used increased after assign");
    ok(exists $r->assignments->{'job_abc'}, "assignment recorded");
    ok(exists $env->{T2_HARNESS_MY_JOB_CONCURRENCY}, "env var set");

    my $used_after_assign = $r->used;

    $r->release('job_abc', $fake_job);

    is($r->used, 0, "used decremented after release");
    ok(!exists $r->assignments->{'job_abc'}, "assignment removed after release");
};

subtest release_invalid_id_dies => sub {
    my $r = CLASS->new(slots => 4, job_slots => 4);
    like(
        dies { $r->release('no_such_id', $fake_job) },
        qr/Invalid release ID/,
        "release with bad id dies"
    );
};

subtest resource_name => sub {
    is(CLASS->resource_name,   'jobcount', "resource_name is 'jobcount'");
    is(CLASS->resource_io_tag, 'JOBCOUNT', "resource_io_tag is 'JOBCOUNT'");
};

done_testing;
