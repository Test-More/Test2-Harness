use Test2::V0;

use App::Yath2::Role::Plugin;

# Stubby CLI plugin. Because App::Yath2::Role::Plugin consumes the
# harness-side role, this consumer is also a valid harness-side
# plugin automatically.
package YathBare;
use Role::Tiny::With;
with 'App::Yath2::Role::Plugin';
sub new { bless {}, shift }

package YathOver;
use Role::Tiny::With;
with 'App::Yath2::Role::Plugin';
sub new { bless { seen => [] }, shift }
sub seen { $_[0]->{seen} }
sub client_setup {
    my $self = shift;
    push @{ $self->{seen} } => [client_setup => {@_}];
    return;
}
sub client_teardown {
    my $self = shift;
    push @{ $self->{seen} } => [client_teardown => {@_}];
    return;
}
sub client_finalize {
    my $self = shift;
    push @{ $self->{seen} } => [client_finalize => {@_}];
    return;
}
sub sort_files_2 {
    my ($self, %args) = @_;
    my $files = $args{files} // [];
    return sort @$files;
}
sub args_from_settings {
    return (opt_a => 1, opt_b => 2);
}

package main;

subtest 'role consumption' => sub {
    ok(Role::Tiny::does_role('YathBare', 'App::Yath2::Role::Plugin'),
        'YathBare consumes the CLI plugin role');
    ok(Role::Tiny::does_role('YathBare', 'Test2::Harness2::Role::Plugin'),
        'YathBare transitively consumes the harness plugin role');
    ok(Role::Tiny::does_role('YathOver', 'Test2::Harness2::Role::Plugin'),
        'YathOver transitively consumes the harness plugin role');
};

subtest 'CLI hook defaults are no-ops' => sub {
    my $p = YathBare->new;

    ok(lives { $p->client_setup(settings    => {}) }, 'client_setup ok');
    ok(lives { $p->client_teardown(settings => {}) }, 'client_teardown ok');
    ok(lives { $p->client_finalize(settings => {}) }, 'client_finalize ok');
    ok(lives { $p->sort_files_2(settings => {}, files => []) }, 'sort_files_2 ok');
    ok(lives { $p->sort_files([]) }, 'sort_files ok');

    is([$p->args_from_settings({})], [], 'args_from_settings default empty list');
};

subtest 'inherited harness hooks still available' => sub {
    my $p = YathBare->new;

    ok(lives { $p->tick(type => 'run') },       'tick from harness role');
    ok(lives { $p->run_queued({}) },            'run_queued from harness role');
    is($p->claim_file('t/x.t', {}), undef,      'claim_file from harness role');
    is([$p->changed_files({})], [],             'changed_files from harness role');
};

subtest 'overriding hooks dispatches correctly' => sub {
    my $p = YathOver->new;

    $p->client_setup(settings => 'S1');
    $p->client_teardown(settings => 'S2');
    $p->client_finalize(settings => 'S3', exit => \0);

    my @names = map { $_->[0] } @{ $p->seen };
    is(\@names,
        [qw/client_setup client_teardown client_finalize/],
        'lifecycle dispatch in order',
    );
    is($p->seen->[0][1]{settings}, 'S1', 'client_setup got its args');
    is($p->seen->[1][1]{settings}, 'S2', 'client_teardown got its args');
    is($p->seen->[2][1]{settings}, 'S3', 'client_finalize got its args');

    is([$p->sort_files_2(files => ['b.t', 'a.t', 'c.t'])],
        ['a.t', 'b.t', 'c.t'],
        'sort_files_2 overridden',
    );
    is({$p->args_from_settings({})},
        {opt_a => 1, opt_b => 2},
        'args_from_settings overridden',
    );
};

done_testing;
