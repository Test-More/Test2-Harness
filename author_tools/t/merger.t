use strict;
use warnings;
use Test2::V0;

use lib 'author_tools/lib';
use Yath::Regen::DBIC::Merger qw/merge_backends/;
use Yath::Regen::DBIC::Branch;

sub col { +{ name => $_[0], spec => $_[1] } }
sub mk {
    my (%cols) = @_;
    return {
        package     => 'App::Yath::Schema::Result::Foo',
        table       => 'foos',
        components  => [],
        columns     => [ map { col($_->[0], $_->[1]) } @{ $cols{columns} } ],
        primary_key => ['foo_id'],
        unique_constraints => [],
        relationships      => [],
    };
}

# Case 1: all backends identical — no branches emitted.
{
    my $spec = mk(columns => [
        ['foo_id', { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 }],
        ['name',   { data_type => 'varchar', size => 64, is_nullable => 0 }],
    ]);
    my $merged = merge_backends(
        SQLite     => $spec,
        PostgreSQL => $spec,
        MySQL      => $spec,
        MariaDB    => $spec,
        Percona    => $spec,
    );
    is($merged->{columns}[0]{spec}{data_type}, 'integer', 'identical across backends: plain value');
    ok(
        !ref $merged->{columns}[0]{spec}{data_type}
          || ref $merged->{columns}[0]{spec}{data_type} ne 'Yath::Regen::DBIC::Branch',
        'not branched when identical',
    );
}

# Case 2: data_type differs between SQLite and the rest — branched.
{
    my $sqlite_spec = mk(columns => [
        ['foo_id', { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 }],
    ]);
    my $pg_spec = mk(columns => [
        ['foo_id', { data_type => 'bigint',  is_auto_increment => 1, is_nullable => 0 }],
    ]);
    my $merged = merge_backends(
        SQLite     => $sqlite_spec,
        PostgreSQL => $pg_spec,
        MySQL      => $pg_spec,
        MariaDB    => $pg_spec,
        Percona    => $pg_spec,
    );
    my $dt = $merged->{columns}[0]{spec}{data_type};
    isa_ok($dt, ['Yath::Regen::DBIC::Branch'], 'data_type is a Branch on disagreement');
    is($dt->value_for('SQLite'),     'integer', 'SQLite value preserved');
    is($dt->value_for('PostgreSQL'), 'bigint',  'PostgreSQL value preserved');
    is($dt->value_for('MySQL'),      'bigint',  'MySQL value preserved');

    # is_auto_increment and is_nullable should NOT be branched (all agree).
    is($merged->{columns}[0]{spec}{is_auto_increment}, 1, 'is_auto_increment unbranched');
    ok(
        ref $merged->{columns}[0]{spec}{is_auto_increment} ne 'Yath::Regen::DBIC::Branch',
        'is_auto_increment not a Branch',
    );
}

# Case 3: a column present in PG but missing elsewhere → die loudly.
{
    my $with_extra = mk(columns => [
        ['foo_id', { data_type => 'integer' }],
        ['extra',  { data_type => 'text' }],
    ]);
    my $without = mk(columns => [
        ['foo_id', { data_type => 'integer' }],
    ]);
    like(
        dies {
            merge_backends(
                SQLite     => $without,
                PostgreSQL => $with_extra,
                MySQL      => $without,
                MariaDB    => $without,
                Percona    => $without,
            );
        },
        qr/column presence mismatch/i,
        'mismatched column presence dies loudly',
    );
}

# Case 4: Branch->grouped groups backends by shared value.
{
    my $branch = Yath::Regen::DBIC::Branch->new(
        per_backend => {
            SQLite     => 'integer',
            PostgreSQL => 'bigint',
            MySQL      => 'bigint',
            MariaDB    => 'bigint',
            Percona    => 'bigint',
        },
    );
    my $groups = $branch->grouped;
    is(scalar @$groups, 2, 'two distinct value groups');
    # The 'bigint' group has 4 backends, the 'integer' group has 1.
    my ($big)  = grep { $_->[1] eq 'bigint'  } @$groups;
    my ($int)  = grep { $_->[1] eq 'integer' } @$groups;
    is(scalar @{ $big->[0] }, 4, 'bigint grouped 4 backends');
    is(scalar @{ $int->[0] }, 1, 'integer grouped 1 backend');
}

done_testing;
