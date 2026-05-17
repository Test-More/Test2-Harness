use Test2::V0;
use App::Yath2::Log::Producer::Run;

isa_ok('App::Yath2::Log::Producer::Run', ['App::Yath2::Log::Producer']);

# kind defaults to 'run' when omitted
my $p = App::Yath2::Log::Producer::Run->new(
    id    => '42',
    state => 'partial',
    log   => undef,
);
is($p->kind, 'run', 'kind defaults to run');

# accessors for the Run-specific extras
ok($p->can('pass'), 'has pass accessor');
ok($p->can('exit'), 'has exit accessor');
is($p->pass, undef, 'pass defaults to undef');
is($p->exit, undef, 'exit defaults to undef');

# round-trip values
my $sealed = App::Yath2::Log::Producer::Run->new(
    id    => '42',
    state => 'sealed',
    log   => undef,
    pass  => 1,
    exit  => 0,
);
is($sealed->pass, 1, 'pass round-trips');
is($sealed->exit, 0, 'exit round-trips');

# explicit kind=run still accepted (forward compat)
my $explicit = App::Yath2::Log::Producer::Run->new(
    id    => '42',
    kind  => 'run',
    state => 'partial',
    log   => undef,
);
is($explicit->kind, 'run', 'explicit kind=run accepted');

done_testing;
