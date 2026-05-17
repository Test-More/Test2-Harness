use Test2::V0;
use Test2::Harness2;
use Test2::Harness2::PidIndex;
use Test2::Harness2::PreloadRouter;
use Scalar::Util ();

# Minimal stub: resource object exposing name + is_permanent_broken.
{
    package FakeRes;
    sub new { bless { name => $_[1], broken => $_[2] // 0 }, 'FakeRes' }
    sub name { $_[0]->{name} }
    sub is_permanent_broken { $_[0]->{broken} }
}

my $alive = $$;
my $dead  = 999999999;   # almost certainly not a live pid

# find_eligible now reads $h->pid_index->resource_services, so seed
# the pid index with the same fixture data the harness's
# RESOURCE_SERVICES used to carry.
my $pid_index = Test2::Harness2::PidIndex->new;
%{$pid_index->resource_services} = (
    $alive => {
        service_class => 'Test2::Harness2::PreloadService',
        scope         => 'global',
        name          => 'preload-myapp',
        pid           => $alive,
        resource      => FakeRes->new('myapp'),
    },
    $dead => {
        service_class => 'Test2::Harness2::PreloadService',
        scope         => 'global',
        name          => 'preload-stale',
        pid           => $dead,
        resource      => FakeRes->new('stale'),
    },
    # Non-preload service: ignored.
    ($alive + 1) => {
        service_class => 'Test2::Harness2::Resource::JobCount',
        scope         => 'global',
        name          => 'jobcount',
        pid           => $alive,
        resource      => FakeRes->new('jobcount'),
    },
    # Run-scoped preload with matching name: ineligible (initial
    # design covers global-scope preloads only).
    ($alive + 2) => {
        service_class => 'Test2::Harness2::PreloadService',
        scope         => 'run',
        name          => 'preload-myapp',
        pid           => $alive,
        resource      => FakeRes->new('myapp'),
        run           => 1,
    },
    # Permanent_broken preload with matching name: ineligible.
    ($alive + 3) => {
        service_class => 'Test2::Harness2::PreloadService',
        scope         => 'global',
        name          => 'preload-broken',
        pid           => $alive,
        resource      => FakeRes->new('broken', 1),  # broken=1
    },
);

my $harness = bless { pid_index => $pid_index }, 'Test2::Harness2';

# Eligibility lookup lives on the preload router; attach a stub
# router that holds a backref to the harness for the resource_services
# lookup.
my $router = bless { harness => $harness }, 'Test2::Harness2::PreloadRouter';
Scalar::Util::weaken($router->{harness});
$harness->{preload_router} = $router;

my $info = $router->find_eligible('myapp');
ok($info, 'found eligible preload') or diag explain $info;
is($info->{name}, 'preload-myapp', 'returned the live global preload');

is(
    $router->find_eligible('stale'),
    undef,
    'stale (pid dead) preload is rejected',
);

is(
    $router->find_eligible('broken'),
    undef,
    'permanent_broken preload is rejected',
);

is(
    $router->find_eligible('absent'),
    undef,
    'name with no matching preload returns undef',
);

done_testing;
