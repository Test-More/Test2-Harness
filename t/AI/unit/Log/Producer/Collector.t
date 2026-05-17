use Test2::V0;
use App::Yath2::Log::Producer::Collector;

isa_ok('App::Yath2::Log::Producer::Collector', ['App::Yath2::Log::Producer']);

# kind defaults to 'collector' when omitted
my $p = App::Yath2::Log::Producer::Collector->new(
    id    => 'col-1',
    state => 'partial',
    log   => undef,
);
is($p->kind, 'collector', 'kind defaults to collector');

# partial state constructs successfully
my $partial = App::Yath2::Log::Producer::Collector->new(
    id    => 'col-partial',
    state => 'partial',
    log   => undef,
);
is($partial->state, 'partial', 'partial state accepted');

# sealed state constructs successfully
my $sealed = App::Yath2::Log::Producer::Collector->new(
    id    => 'col-sealed',
    state => 'sealed',
    log   => undef,
);
is($sealed->state, 'sealed', 'sealed state accepted');

# missing state (default) constructs successfully
my $missing = App::Yath2::Log::Producer::Collector->new(
    id  => 'col-missing',
    log => undef,
);
is($missing->state, 'missing', 'missing state is the default');

# invalid state is still rejected by the base class
ok(
    dies { App::Yath2::Log::Producer::Collector->new(id => 'x', state => 'bogus') },
    'invalid state dies',
);

done_testing;
