use Test2::V0;
use App::Yath2::Log::Producer::Service;

isa_ok('App::Yath2::Log::Producer::Service', ['App::Yath2::Log::Producer']);

# kind defaults to 'service' when omitted
my $p = App::Yath2::Log::Producer::Service->new(
    id    => 'svc-1',
    state => 'partial',
    log   => undef,
);
is($p->kind, 'service', 'kind defaults to service');

# global service (no parent_id / run_id) constructs successfully
my $global = App::Yath2::Log::Producer::Service->new(
    id    => 'svc-global',
    state => 'missing',
    log   => undef,
);
is($global->kind,      'service', 'global service kind');
is($global->parent_id, undef,     'global service has no parent_id');
is($global->run_id,    undef,     'global service has no run_id');

# run-scoped service (with parent_id + run_id) constructs successfully
my $scoped = App::Yath2::Log::Producer::Service->new(
    id        => 'svc-scoped',
    state     => 'partial',
    log       => undef,
    parent_id => 'run-1',
    run_id    => 'run-1',
);
is($scoped->kind,      'service', 'scoped service kind');
is($scoped->parent_id, 'run-1',   'scoped service parent_id');
is($scoped->run_id,    'run-1',   'scoped service run_id');

done_testing;
