use strict;
use warnings;
use Test2::V0;

use lib 'author_tools/lib';
use Yath::Regen::DBIC::Emitter qw/emit_result_body/;
use Yath::Regen::DBIC::Branch;

# Minimal spec: one column, identical across backends.
my $simple = {
    package    => 'App::Yath::Schema::Result::Foo',
    table      => 'foos',
    components => ['InflateColumn::DateTime'],
    columns    => [
        {
            name => 'foo_id',
            spec => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
        },
    ],
    primary_key        => ['foo_id'],
    unique_constraints => [],
    relationships      => [],
};

my $out = emit_result_body($simple);
like($out, qr/__PACKAGE__->table\("foos"\)/, 'table emitted');
like($out, qr/__PACKAGE__->load_components/, 'load_components emitted');
like($out, qr/"foo_id"/,                     'column name emitted');
like($out, qr/data_type\s*=>\s*"integer"/,   'data_type emitted');
like($out, qr/__PACKAGE__->set_primary_key\("foo_id"\)/, 'primary key emitted');
unlike($out, qr/is_sqlite|is_postgresql/, 'no branching when not needed');

# Spec with a branched column.
my $branched = {
    package    => 'App::Yath::Schema::Result::Foo',
    table      => 'foos',
    components => [],
    columns    => [
        {
            name => 'foo_id',
            spec => {
                data_type => Yath::Regen::DBIC::Branch->new(per_backend => {
                    SQLite     => 'integer',
                    PostgreSQL => 'bigint',
                    MySQL      => 'bigint',
                    MariaDB    => 'bigint',
                    Percona    => 'bigint',
                }),
                is_auto_increment => 1,
                is_nullable       => 0,
            },
        },
    ],
    primary_key        => ['foo_id'],
    unique_constraints => [],
    relationships      => [],
};

my $out2 = emit_result_body($branched);
like($out2, qr/is_postgresql|is_sqlite|is_mysql|is_mariadb|is_percona/, 'branched column emits helper call');
like($out2, qr/"bigint"/, 'bigint value present');
like($out2, qr/"integer"/, 'integer value present');

# Spec with relationships.
my $with_rel = {
    package    => 'App::Yath::Schema::Result::Foo',
    table      => 'foos',
    components => [],
    columns    => [{ name => 'foo_id', spec => { data_type => 'integer' } }],
    primary_key        => ['foo_id'],
    unique_constraints => [{ name => 'name_unique', cols => ['name'] }],
    relationships      => [
        {
            kind   => 'has_many',
            name   => 'bars',
            target => 'App::Yath::Schema::Result::Bar',
            cond   => { 'foreign.foo_id' => 'self.foo_id' },
            attrs  => { cascade_copy => 0, cascade_delete => 1 },
        },
    ],
};

my $out3 = emit_result_body($with_rel);
like($out3, qr/__PACKAGE__->add_unique_constraint\("name_unique"/, 'unique constraint emitted');
like($out3, qr/__PACKAGE__->has_many\(\s*"bars"/, 'has_many emitted');
like($out3, qr/"App::Yath::Schema::DBIC::Result::Bar"/, 'relationship target rewritten to DBIC namespace');

# Sanity: emitted source should be syntactically valid Perl when wrapped
# in a package + __PACKAGE__->stub. This catches quoting bugs.
{
    my $wrapper = <<"PERL";
package Foo::Test;
sub __PACKAGE__ { "Foo::Test" }
our \%calls;
my \$table_of;
sub load_components { shift; \$calls{load_components} = [\@_] }
sub table { shift; \$table_of = \$_[0] }
sub add_columns { shift; \$calls{add_columns} = [\@_] }
sub set_primary_key { shift; \$calls{primary_key} = [\@_] }
sub add_unique_constraint { shift; push \@{\$calls{uc}}, [\@_] }
sub has_many { shift; push \@{\$calls{rels}}, ['has_many', \@_] }
sub is_sqlite     { 1 }  # pretend we are SQLite for this smoke test
sub is_postgresql { 0 }
sub is_mysql      { 0 }
sub is_mariadb    { 0 }
sub is_percona    { 0 }
$out3
1;
PERL
    my $ok = eval $wrapper;
    ok($ok, 'emitted source is syntactically valid Perl') or diag $@;
}

done_testing;
