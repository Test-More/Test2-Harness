use Test2::V0;

# Consumer package defined in-test so we can exercise the role machinery
# independently of any concrete Resource class.
{

    package My::TinyResource;
    use Object::HashBase qw/<available_val +broken +permanent_broken +paused/;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Resource';

    sub available { $_[0]->{+AVAILABLE_VAL} // 1 }
    sub assign    { 1 }
    sub release   { 1 }
    sub status    { {ok => 1} }

    sub is_broken           { $_[0]->{+BROKEN}           ? 1 : 0 }
    sub is_permanent_broken { $_[0]->{+PERMANENT_BROKEN} ? 1 : 0 }
    sub is_paused           { $_[0]->{+PAUSED}           ? 1 : 0 }

    sub mark_broken { $_[0]->{+BROKEN} = 1 }

    sub mark_permanent_broken {
        my $self = shift;
        $self->{+PERMANENT_BROKEN} = 1;
        $self->{+BROKEN}           = 1;
    }
    sub mark_paused { $_[0]->{+PAUSED} = 1 }

    sub mark_resumed {
        my $self = shift;
        $self->{+BROKEN} = 0;
        $self->{+PAUSED} = 0;
    }

    sub service_alpha_start { -1 }
    sub service_beta_start  { 0 }
}

{

    package My::LimiterResource;
    use Object::HashBase;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Resource';

    sub is_job_limiter { 1 }

    sub available { 1 }
    sub assign    { 1 }
    sub release   { 1 }
    sub status    { {ok => 1} }

    sub mark_broken           { }
    sub mark_permanent_broken { }
    sub mark_paused           { }
    sub mark_resumed          { }
}

subtest 'role is applied and provides defaults' => sub {
    my $r = My::TinyResource->new;
    ok($r->DOES('Test2::Harness2::Role::Resource'), 'role composed');
    is($r->is_job_limiter, 0, 'default is_job_limiter=0');
    ok($r->needed, 'default needed=1');
    is($r->resource_name, 'tinyresource', 'default name is lc(last :: part)');
};

subtest 'is_job_limiter override' => sub {
    my $r = My::LimiterResource->new;
    ok($r->is_job_limiter, 'flag set');
};

subtest 'state transitions' => sub {
    my $r = My::TinyResource->new;
    ok($r->is_usable, 'usable by default');

    $r->mark_broken;
    ok($r->is_broken,  'is_broken');
    ok(!$r->is_usable, 'not usable when broken');

    $r->mark_resumed;
    ok(!$r->is_broken, 'broken cleared');
    ok($r->is_usable,  'usable again');

    $r->mark_paused;
    ok($r->is_paused,  'paused');
    ok(!$r->is_usable, 'not usable when paused');

    $r->mark_resumed;
    ok(!$r->is_paused, 'pause cleared');

    $r->mark_permanent_broken;
    ok($r->is_permanent_broken, 'permanent broken set');
    ok($r->is_broken,           'also marks broken');
    $r->mark_resumed;
    ok(
        $r->is_permanent_broken,
        'permanent brokenness is sticky across mark_resumed'
    );
};

subtest 'service_methods enumerates service_*_start subs only' => sub {
    my @m = My::TinyResource->service_methods;
    is(\@m, ['service_alpha_start', 'service_beta_start'], 'sorted list of service_*_start methods');

    my @n = My::LimiterResource->service_methods;
    is(\@n, [], 'empty list when no service_*_start methods');
};

subtest 'sort_methods default is alphabetical; overrideable' => sub {
    {

        package My::OrderedResource;
        use Object::HashBase;
        use Role::Tiny::With;
        with 'Test2::Harness2::Role::Resource';

        sub available { 1 }
        sub assign    { 1 }
        sub release   { 1 }
        sub status    { {} }

        sub service_db_start     { 1 }
        sub service_worker_start { 1 }

        # worker depends on db, so explicit ordering reverses the
        # alphabetical default.
        sub sort_methods {
            my $self = shift;
            return sort { ($a eq 'service_db_start') <=> ($b eq 'service_db_start') || $a cmp $b } @_;
        }
    }

    my @default = My::TinyResource->service_methods;
    is(\@default, ['service_alpha_start', 'service_beta_start'], 'default sort is alphabetical');

    my @ordered = My::OrderedResource->service_methods;
    is(\@ordered, ['service_worker_start', 'service_db_start'], 'override steers startup order');
};

done_testing;
