use Test2::V0;
use App::Yath2::Log::Producer::Job;

isa_ok('App::Yath2::Log::Producer::Job', ['App::Yath2::Log::Producer']);

# kind defaults to 'job' when omitted
my $p = App::Yath2::Log::Producer::Job->new(
    id    => '42',
    state => 'partial',
    log   => undef,
);
is($p->kind, 'job', 'kind defaults to job');

# accessors for the Job-specific extras
ok($p->can('try'),              'has try accessor');
ok($p->can('pass'),             'has pass accessor');
ok($p->can('report_available'), 'has report_available accessor');

# defaults all undef when not supplied
is($p->try,              undef, 'try defaults to undef');
is($p->pass,             undef, 'pass defaults to undef');
is($p->report_available, undef, 'report_available defaults to undef');

# round-trip values
my $sealed = App::Yath2::Log::Producer::Job->new(
    id               => '99',
    state            => 'sealed',
    log              => undef,
    try              => 0,
    pass             => 1,
    report_available => 1,
);
is($sealed->try,              0, 'try round-trips');
is($sealed->pass,             1, 'pass round-trips');
is($sealed->report_available, 1, 'report_available round-trips');

# explicit kind=job still accepted
my $explicit = App::Yath2::Log::Producer::Job->new(
    id    => '42',
    kind  => 'job',
    state => 'partial',
    log   => undef,
);
is($explicit->kind, 'job', 'explicit kind=job accepted');

done_testing;
