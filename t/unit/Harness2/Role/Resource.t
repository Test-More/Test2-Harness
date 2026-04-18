use Test2::V0;

# Consumer package defined in-test so we can exercise the role machinery
# independently of any concrete Resource class.
{

    package My::TinyResource;
    use Object::HashBase qw/<available_val/;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Resource';

    sub available { $_[0]->{+AVAILABLE_VAL} // 1 }
    sub assign    { 1 }
    sub release   { 1 }
    sub status    { {ok => 1} }

    sub service_alpha { -1 }
    sub service_beta  { 0 }
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
}

subtest 'role is applied and provides defaults' => sub {
    my $r = My::TinyResource->new;
    ok($r->DOES('Test2::Harness2::Role::Resource'), 'role composed');
    is($r->is_job_limiter, 0, 'default is_job_limiter=0');
    ok($r->applicable, 'default applicable=1');
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

subtest 'service_methods enumerates only service_* subs' => sub {
    my @m = My::TinyResource->service_methods;
    is(\@m, ['service_alpha', 'service_beta'], 'sorted list of service_* methods');

    my @n = My::LimiterResource->service_methods;
    is(\@n, [], 'empty list when no service_* methods');
};

done_testing;
