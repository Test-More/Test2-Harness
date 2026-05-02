use Test2::V0;

# Verify the Resource option group correctly parses every form of the
# -j (slots) and -x (job_slots) flags, including the combined -j N:M
# syntax that the trigger splits, every long alias, and the env var
# fallbacks documented on each option.

package TestResource {
    use Getopt::Yath;
    include_options('App::Yath2::Options::Resource');
}

sub parse {
    my @argv = @_;
    local %ENV = %ENV;
    delete @ENV{qw/YATH_JOB_COUNT T2_HARNESS_JOB_COUNT HARNESS_JOB_COUNT T2_HARNESS_JOB_CONCURRENCY/};
    my $state = TestResource::parse_options([@argv]);
    return $state->{settings}->resource;
}

sub parse_with_env {
    my ($env, @argv) = @_;
    local %ENV = (%ENV, %$env);
    my $state = TestResource::parse_options([@argv]);
    return $state->{settings}->resource;
}

subtest '-j N short form' => sub {
    my $r = parse('-j', '8');
    is($r->slots,     8, 'slots from -j');
    is($r->job_slots, 1, 'job_slots default 1');
};

subtest '-j N:M combined form' => sub {
    my $r = parse('-j', '8:2');
    is($r->slots,     8, 'slots from N portion');
    is($r->job_slots, 2, 'job_slots from M portion');
};

subtest '--slots N' => sub {
    my $r = parse('--slots', '6');
    is($r->slots,     6, 'slots from --slots');
    is($r->job_slots, 1, 'job_slots default 1');
};

subtest '--jobs N alias' => sub {
    my $r = parse('--jobs', '4');
    is($r->slots, 4, 'slots from --jobs');
};

subtest '--job-count N alias' => sub {
    my $r = parse('--job-count', '5');
    is($r->slots, 5, 'slots from --job-count');
};

subtest '-x M short form' => sub {
    my $r = parse('-j', '6', '-x', '3');
    is($r->slots,     6, 'slots');
    is($r->job_slots, 3, 'job_slots from -x');
};

subtest '--slots-per-job M alias' => sub {
    my $r = parse('-j', '6', '--slots-per-job', '2');
    is($r->job_slots, 2, 'job_slots from --slots-per-job');
};

subtest '--job-slots M long form' => sub {
    my $r = parse('-j', '4', '--job-slots', '2');
    is($r->job_slots, 2, 'job_slots from --job-slots');
};

subtest 'YATH_JOB_COUNT env var' => sub {
    my $r = parse_with_env({YATH_JOB_COUNT => 7});
    is($r->slots, 7, 'slots from YATH_JOB_COUNT');
};

subtest 'T2_HARNESS_JOB_COUNT env var' => sub {
    my $r = parse_with_env({T2_HARNESS_JOB_COUNT => 9});
    is($r->slots, 9, 'slots from T2_HARNESS_JOB_COUNT');
};

subtest 'HARNESS_JOB_COUNT env var' => sub {
    my $r = parse_with_env({HARNESS_JOB_COUNT => 3});
    is($r->slots, 3, 'slots from HARNESS_JOB_COUNT');
};

subtest 'T2_HARNESS_JOB_CONCURRENCY env var for job_slots' => sub {
    my $r = parse_with_env({YATH_JOB_COUNT => 8, T2_HARNESS_JOB_CONCURRENCY => 4});
    is($r->slots,     8, 'slots from YATH_JOB_COUNT');
    is($r->job_slots, 4, 'job_slots from T2_HARNESS_JOB_CONCURRENCY');
};

subtest '-j N:M overrides -x argument order' => sub {
    # -j parses second; trigger writes group->{job_slots}=2 directly
    my $r = parse('-x', '5', '-j', '8:2');
    is($r->slots,     8, 'slots from N');
    is($r->job_slots, 2, 'N:M trigger overrides earlier -x');
};

subtest 'job_slots > slots is rejected' => sub {
    my $err = dies { parse('-j', '4', '-x', '8') };
    like(
        $err,
        qr/slots per job .* must not be larger than .* total number of slots/,
        'post-process rejects job_slots > slots',
    );
};

subtest 'JobCount default resource registered' => sub {
    my $r = parse('-j', '4');
    ok(
        exists $r->classes->{'Test2::Harness2::Resource::JobCount'},
        'JobCount auto-registered when no other resource is supplied',
    );
};

subtest '--no-resource disables JobCount auto-injection' => sub {
    my $r = parse('--no-resource');
    is(
        scalar keys %{$r->classes},
        0,
        '--no-resource leaves classes empty (unlimited concurrency)',
    );
    ok($r->check_option('no_resource'), 'no_resource flag recorded by classes trigger');
    ok($r->no_resource,                 'no_resource setting reflects opt-in');
};

subtest '--no-resources (plural) also disables auto-injection' => sub {
    my $r = parse('--no-resources');
    is(scalar keys %{$r->classes}, 0, '--no-resources leaves classes empty');
    ok($r->check_option('no_resource'), 'plural form sets the same flag');
};

subtest '--no-resource followed by -R: -R wins' => sub {
    # Order matters: --no-resource clears, then -R adds back. The
    # post-process step checks the resulting classes hash; if it has
    # entries we use them, regardless of an earlier clear.
    my $r = parse('--no-resource', '-R', '+Test2::Harness2::Resource::JobCount');
    ok(
        exists $r->classes->{'Test2::Harness2::Resource::JobCount'},
        '-R after --no-resource still wires the resource through',
    );
};

subtest '--utilize accepts valid percentages' => sub {
    my $r = parse('-U', '50');
    is($r->utilize, 50, '-U 50 stored');

    my $r2 = parse('--utilize', '99.5');
    is($r2->utilize, 99.5, '--utilize 99.5 stored');
};

subtest '--utilize rejects out-of-range and non-numeric values' => sub {
    like(dies { parse('-U', '0') },     qr/--utilize must be greater than 0/);
    like(dies { parse('-U', '100') },   qr/--utilize must be greater than 0/);
    like(dies { parse('-U', '-5') },    qr/--utilize must be a number/);
    like(dies { parse('-U', 'fifty') }, qr/--utilize must be a number/);
};

done_testing;
