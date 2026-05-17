use Test2::V0;

# Pure-logic test of _resolve_preload_for_job. We build a tiny harness
# stub (bless { resources => [...] }, 'Test2::Harness2') and stub Run /
# Job / TestFile shims so we never spin up a real harness. The resolver
# only reads from $self->{resources} + $job->test_file->preload_preferences
# + $run->run_id.

use Test2::Harness2;
use Test2::Harness2::PreloadRouter;
use Test2::Harness2::Resource::Preload;

sub make_preload {
    my %args = @_;
    my $r = Test2::Harness2::Resource::Preload->new(
        name             => $args{name},
        modules          => $args{modules} // [],
        scope            => $args{scope}   // 'global',
        ($args{scope} && $args{scope} eq 'run'
            ? (run => bless { run_id => $args{run_id} // 'R1' }, 'Test2::Harness2::Test::FakeRun')
            : ()),
        is_role_consumer => $args{is_role_consumer} // 0,
    );
    $r->mark_ready                if $args{usable};
    $r->mark_broken               if $args{transient_broken};
    $r->mark_permanent_broken     if $args{permanent_broken};
    return $r;
}

sub make_run { bless { run_id => $_[0] // 'R1' }, 'Test2::Harness2::Test::FakeRun' }

sub make_job {
    my @prefs = @_;
    my $tf = bless { _prefs => [@prefs] }, 'Test2::Harness2::Test::FakeTestFile';
    return bless { test_file => $tf }, 'Test2::Harness2::Test::FakeJob';
}

# minimum stubs so the resolver can read what it needs
{
    no strict 'refs';
    *Test2::Harness2::Test::FakeRun::run_id    = sub { $_[0]->{run_id} };
    *Test2::Harness2::Test::FakeRun::resources = sub { $_[0]->{resources} // [] };
    *Test2::Harness2::Test::FakeTestFile::preload_preferences = sub { $_[0]->{_prefs} };
    *Test2::Harness2::Test::FakeJob::test_file = sub { $_[0]->{test_file} };
}

sub make_harness {
    my @resources = @_;
    my $h = bless { resources => \@resources }, 'Test2::Harness2';
    # The resolver lives on PreloadRouter now; bolt a stub router onto
    # the harness so the shim can delegate. The router only reads the
    # harness's RESOURCES slot via its harness backref, so a stub
    # blessed into the right class with a weakened harness ref does
    # not need full ctor wiring.
    my $router = bless {
        harness                => $h,
        pending_spawn_requests => {},
    }, 'Test2::Harness2::PreloadRouter';
    require Scalar::Util;
    Scalar::Util::weaken($router->{harness});
    $h->{preload_router} = $router;
    return $h;
}

subtest '<no> returns no_preload' => sub {
    my $h = make_harness();
    my @r = $h->_resolve_preload_for_job(make_run(), make_job('<no>'));
    is(\@r, [undef, 'no_preload'], '<no> resolves immediately');
};

subtest 'empty list defaults to <default> -> no_preload when no default exists' => sub {
    my $h = make_harness();
    my @r = $h->_resolve_preload_for_job(make_run(), make_job('<default>'));
    is(\@r, [undef, 'no_preload'], '<default> with no global default falls through to no_preload');
};

subtest 'name match: per-run takes precedence over global' => sub {
    my $global = make_preload(name => 'mypl', scope => 'global', usable => 1);
    my $perrun = make_preload(name => 'mypl', scope => 'run', run_id => 'R1', usable => 1);
    my $h = make_harness($global, $perrun);
    my @r = $h->_resolve_preload_for_job(make_run('R1'), make_job('mypl'));
    is($r[0], $perrun, 'per-run match preferred');
    is($r[1], 'preload', 'kind=preload');
};

subtest 'name match: per-run from different run does not satisfy' => sub {
    my $other_run = make_preload(name => 'mypl', scope => 'run', run_id => 'R2', usable => 1);
    my $global    = make_preload(name => 'mypl', scope => 'global', usable => 1);
    my $h = make_harness($other_run, $global);
    my @r = $h->_resolve_preload_for_job(make_run('R1'), make_job('mypl'));
    is($r[0], $global, 'global match used when run scope mismatches');
};

subtest 'name match: global usable' => sub {
    my $r1 = make_preload(name => 'foo', scope => 'global', usable => 1);
    my $h  = make_harness($r1);
    my @r  = $h->_resolve_preload_for_job(make_run(), make_job('foo'));
    is(\@r, [$r1, 'preload'], 'usable global named match');
};

subtest 'permanent_broken skips to next entry' => sub {
    my $bad  = make_preload(name => 'a', scope => 'global', permanent_broken => 1);
    my $good = make_preload(name => 'b', scope => 'global', usable => 1);
    my $h = make_harness($bad, $good);
    my @r = $h->_resolve_preload_for_job(make_run(), make_job('a', 'b'));
    is(\@r, [$good, 'preload'], 'b chosen after a is permanent_broken');
};

subtest 'all candidates permanent_broken returns broken + first name' => sub {
    my $bad = make_preload(name => 'a', scope => 'global', permanent_broken => 1);
    my $h = make_harness($bad);
    my @r = $h->_resolve_preload_for_job(make_run(), make_job('a'));
    is(\@r, [undef, 'broken', 'a'], 'broken + first preferred name');
};

subtest 'transient broken triggers defer' => sub {
    my $t = make_preload(name => 'a', scope => 'global', transient_broken => 1);
    my $h = make_harness($t);
    my @r = $h->_resolve_preload_for_job(make_run(), make_job('a'));
    is(\@r, [undef, 'defer'], 'defer when only candidate is transient broken');
};

subtest 'transient broken followed by usable returns the usable one' => sub {
    my $t = make_preload(name => 'a', scope => 'global', transient_broken => 1);
    my $u = make_preload(name => 'b', scope => 'global', usable => 1);
    my $h = make_harness($t, $u);
    my @r = $h->_resolve_preload_for_job(make_run(), make_job('a', 'b'));
    is(\@r, [$u, 'preload'], 'b chosen over transient-broken a');
};

subtest 'unknown name is broken + first name' => sub {
    my $r1 = make_preload(name => 'foo', scope => 'global', usable => 1);
    my $h  = make_harness($r1);
    my @r  = $h->_resolve_preload_for_job(make_run(), make_job('bar'));
    is(\@r, [undef, 'broken', 'bar'], 'unknown bare name treated as unavailable -> broken');
};

subtest 'unknown name followed by <no> falls through to no_preload' => sub {
    my $r1 = make_preload(name => 'foo', scope => 'global', usable => 1);
    my $h  = make_harness($r1);
    my @r  = $h->_resolve_preload_for_job(make_run(), make_job('bar', '<no>'));
    is(\@r, [undef, 'no_preload'], 'unknown name is skipped, <no> accepted');
};

subtest 'permanent-broken followed by <no> falls through to no_preload' => sub {
    my $r1 = make_preload(name => 'foo', scope => 'global', permanent_broken => 1);
    my $h  = make_harness($r1);
    my @r  = $h->_resolve_preload_for_job(make_run(), make_job('foo', '<no>'));
    is(\@r, [undef, 'no_preload'], 'falls through to <no>');
};

subtest '<default>: global-default = anonymous-merged "default" preload' => sub {
    my $d = make_preload(name => 'default', scope => 'global', usable => 1);
    my $h = make_harness($d);
    my @r = $h->_resolve_preload_for_job(make_run(), make_job('<default>'));
    is(\@r, [$d, 'preload'], '<default> resolves to global default named "default"');
};

subtest '<default>: global single role consumer' => sub {
    my $only = make_preload(name => 'Foo', scope => 'global', is_role_consumer => 1, usable => 1);
    my $h = make_harness($only);
    my @r = $h->_resolve_preload_for_job(make_run(), make_job('<default>'));
    is(\@r, [$only, 'preload'], 'single role-consumer is the global default');
};

subtest '<default>: two role consumers and no "default" → no global default' => sub {
    my $a = make_preload(name => 'A', scope => 'global', is_role_consumer => 1, usable => 1);
    my $b = make_preload(name => 'B', scope => 'global', is_role_consumer => 1, usable => 1);
    my $h = make_harness($a, $b);
    my @r = $h->_resolve_preload_for_job(make_run(), make_job('<default>'));
    is(\@r, [undef, 'no_preload'], 'no global default when multiple role-consumers and no "default"');
};

subtest '<default>: per-run takes precedence over global' => sub {
    my $gd = make_preload(name => 'default', scope => 'global', usable => 1);
    my $rd = make_preload(name => 'Bar', scope => 'run', run_id => 'R1', is_role_consumer => 1, usable => 1);
    my $h = make_harness($gd, $rd);
    my @r = $h->_resolve_preload_for_job(make_run('R1'), make_job('<default>'));
    is(\@r, [$rd, 'preload'], 'per-run default chosen over global default');
};

subtest 'unusable named match returns deferred status (transient) when its scope counterpart not present' => sub {
    my $g = make_preload(name => 'foo', scope => 'global');    # not yet ready
    my $h = make_harness($g);
    my @r = $h->_resolve_preload_for_job(make_run(), make_job('foo'));
    is(\@r, [undef, 'defer'], 'named match that is not yet ready defers');
};

done_testing;
