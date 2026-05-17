use Test2::V0;
use App::Yath2::Log::Producer;

for my $m (qw/id kind parent_id run_id state started_at ended_at artifact_refs log/) {
    ok(App::Yath2::Log::Producer->can($m), "has $m");
}

my $p = App::Yath2::Log::Producer->new(
    id            => 'r1',
    kind          => 'run',
    parent_id     => undef,
    run_id        => 'r1',
    state         => 'partial',
    started_at    => 100,
    ended_at      => undef,
    artifact_refs => {},
    log           => undef,
);

is($p->id,     'r1',      'id');
is($p->kind,   'run',     'kind');
is($p->state,  'partial', 'state');
is($p->run_id, 'r1',      'run_id');

like(
    dies {
        App::Yath2::Log::Producer->new(
            id    => 'x', kind => 'run', log => undef,
            state => 'bogus',
        );
    },
    qr/invalid state/i,
    'rejects bogus state',
);

like(
    dies {
        App::Yath2::Log::Producer->new(
            id    => 'x', kind => 'bogus_kind', log => undef,
            state => 'partial',
        );
    },
    qr/invalid kind/i,
    'rejects bogus kind',
);

# Constructor validation: id required
like(
    dies {
        App::Yath2::Log::Producer->new(
            kind => 'run',
        );
    },
    qr/id.*required/i,
    'croaks when id is missing',
);

# Constructor validation: kind required
like(
    dies {
        App::Yath2::Log::Producer->new(
            id => 'x',
        );
    },
    qr/kind.*required/i,
    'croaks when kind is missing',
);

# state defaults to 'missing' when not provided
my $p2 = App::Yath2::Log::Producer->new(id => 'x', kind => 'run');
is($p2->state, 'missing', 'state defaults to missing');

# artifact_ref: returns stored ref or undef for unknown kind
my $p3 = App::Yath2::Log::Producer->new(
    id            => 'x',
    kind          => 'run',
    artifact_refs => {events => 'some/path'},
);
is($p3->artifact_ref('events'),      'some/path', 'artifact_ref returns stored path');
is($p3->artifact_ref('nonexistent'), undef,       'artifact_ref returns undef for unknown kind');

# artifact: returns undef when no log is attached (early-return path)
my $p4 = App::Yath2::Log::Producer->new(id => 'x', kind => 'run', log => undef);
is($p4->artifact('events'), undef, 'artifact returns undef when log is not set');

done_testing;
