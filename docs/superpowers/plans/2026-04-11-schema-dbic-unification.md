# Schema DBIC Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse the per-database DBIC Result tree plus Overlay tree into a single unified set of Result modules under a new `App::Yath::Schema::DBIC` namespace, rewrite `regen_schema.pl` to produce and preserve them, and restructure per-backend tests around `DBIx::QuickDB`.

**Architecture:** One file per Result class at `lib/App/Yath/Schema/DBIC/Result/<Name>.pm`. Each file has a header, a generator-owned region between `# >>> BEGIN GENERATED - DO NOT EDIT <<<` and `# >>> END GENERATED <<<` markers, and a custom tail below the closing marker that the generator never touches. Column definitions that differ across backends use inline ternary branching over exportable `is_sqlite() / is_postgresql() / is_mysql() / is_mariadb() / is_percona()` helpers. Tests use `DBIx::QuickDB` via `Test2::Tools::QuickDB::skipall_unless_can_db`, with shared logic in reusable modules under `t/lib/App/Yath/Test/DBIC/`.

**Tech Stack:** Perl, DBIx::Class, DBIx::Class::Schema::Loader, DBIx::QuickDB, Test2::V0, Test2::Tools::QuickDB, Exporter.

**Reference:** See `docs/superpowers/specs/2026-04-11-schema-dbic-unification-design.md` for the full design.

---

## Pre-work: branch isolation

This refactor touches ~250 files. Before starting, decide on branch strategy. The current working directory has pre-existing uncommitted changes under `deplib/` and `dist.ini` that are **unrelated to this refactor** — do not touch them. Work on a dedicated branch off `2.0` (e.g. `2.0-schema-dbic-unification`) or in a git worktree. The rest of this plan assumes you are on a clean branch.

Commit boundaries are called out in each task. Prefer many small commits over squashing; `git bisect` across this refactor should remain useful.

---

## Phase 1 — Foundation: the new DBIC.pm module

### Task 1: Create `App::Yath::Schema::DBIC` with exportable helpers

**Files:**
- Create: `lib/App/Yath/Schema/DBIC.pm`
- Create: `t/unit/App/Yath/Schema/DBIC.t`

This task creates the new root module as a `DBIx::Class::Schema` subclass that **also** exports the `is_*` helpers and the UUID helpers as bare subs. It is a full schema class from day one — `load_namespaces` is called on a directory that will be empty until later tasks populate it, which DBIC handles as a no-op.

- [ ] **Step 1: Write the failing test**

Create `t/unit/App/Yath/Schema/DBIC.t`:

```perl
use Test2::V0;

# Simulate a connection module having set $LOADED before use.
BEGIN { $App::Yath::Schema::DBIC::LOADED = 'PostgreSQL' }

use App::Yath::Schema::DBIC qw/
    is_sqlite is_postgresql is_mysql is_mariadb is_percona
    can_store_null_character format_uuid_for_db format_uuid_for_app
/;

ok(is_postgresql(),               'is_postgresql true when LOADED=PostgreSQL');
ok(!is_sqlite(),                  'is_sqlite false');
ok(!is_mysql(),                   'is_mysql false');
ok(!is_mariadb(),                 'is_mariadb false');
ok(!is_percona(),                 'is_percona false');
ok(!can_store_null_character(),   'PostgreSQL cannot store null char');

{
    local $App::Yath::Schema::DBIC::LOADED = 'SQLite';
    ok(is_sqlite(),               'is_sqlite true when LOADED=SQLite');
    ok(!is_postgresql(),          'is_postgresql false');
    ok(can_store_null_character(),'SQLite can store null char');
}

{
    local $App::Yath::Schema::DBIC::LOADED = 'MariaDB';
    ok(is_mysql(),                'is_mysql true for MariaDB (family)');
    ok(is_mariadb(),              'is_mariadb true');
    ok(!is_percona(),             'is_percona false');
}

{
    local $App::Yath::Schema::DBIC::LOADED = 'Percona';
    ok(is_mysql(),                'is_mysql true for Percona (family)');
    ok(is_percona(),              'is_percona true');
}

# UUID round-trip helper sanity: for non-Percona, both functions are identity.
{
    local $App::Yath::Schema::DBIC::LOADED = 'SQLite';
    is(format_uuid_for_db('abc'),  'abc', 'uuid identity for SQLite (to db)');
    is(format_uuid_for_app('abc'), 'abc', 'uuid identity for SQLite (to app)');
}

done_testing;
```

- [ ] **Step 2: Run the test to verify it fails**

```
prove -Ilib t/unit/App/Yath/Schema/DBIC.t
```

Expected: fails with "Can't locate App/Yath/Schema/DBIC.pm in @INC".

- [ ] **Step 3: Create `lib/App/Yath/Schema/DBIC.pm`**

```perl
package App::Yath::Schema::DBIC;
use utf8;
use strict;
use warnings;

our $VERSION = '2.000011';

use base 'DBIx::Class::Schema';

use Carp qw/confess/;
use Exporter 'import';

use Test2::Util::UUID qw/uuid2bin bin2uuid/;

our @EXPORT_OK = qw/
    is_sqlite
    is_postgresql
    is_mysql
    is_mariadb
    is_percona
    can_store_null_character
    format_uuid_for_db
    format_uuid_for_app
/;

sub is_sqlite     { ($App::Yath::Schema::DBIC::LOADED // '') =~ m/SQLite/     ? 1 : 0 }
sub is_postgresql { ($App::Yath::Schema::DBIC::LOADED // '') =~ m/PostgreSQL/ ? 1 : 0 }
sub is_mariadb    { ($App::Yath::Schema::DBIC::LOADED // '') =~ m/MariaDB/    ? 1 : 0 }
sub is_percona    { ($App::Yath::Schema::DBIC::LOADED // '') =~ m/Percona/    ? 1 : 0 }

sub is_mysql {
    return 1 if is_mariadb();
    return 1 if is_percona();
    return 1 if ($App::Yath::Schema::DBIC::LOADED // '') =~ m/MySQL/;
    return 0;
}

sub can_store_null_character {
    return 0 if is_postgresql();
    return 1;
}

sub format_uuid_for_db {
    my ($uuid) = @_;
    return $uuid unless is_percona();
    return uuid2bin($uuid);
}

sub format_uuid_for_app {
    my ($uuid_bin) = @_;
    return $uuid_bin unless is_percona();
    return bin2uuid($uuid_bin);
}

# The check and load_namespaces() call are deferred until Result classes exist.
# For now, DBIC.pm is usable for its exported helpers alone. Task 13 will add
# the schema-class wiring (load_namespaces + the LOADED confess guard) once
# the Result/ directory is populated.

1;
```

**Note:** `is_*` take no arguments (bare subs), unlike the current class-method form on `App::Yath::Schema`. Consumer code that currently calls `$schema->is_postgresql` will be updated in Phase 5 to either call the bare sub or keep the method form (both must work). A later task adds method-form wrappers.

- [ ] **Step 4: Run the test to verify it passes**

```
prove -Ilib t/unit/App/Yath/Schema/DBIC.t
```

Expected: all subtests pass.

- [ ] **Step 5: Commit**

```
git add lib/App/Yath/Schema/DBIC.pm t/unit/App/Yath/Schema/DBIC.t
git commit -m "feat(schema): add App::Yath::Schema::DBIC with exportable helpers"
```

---

### Task 2: Add method-form wrappers for the helpers

Existing consumer code calls `$schema->is_postgresql` and friends as methods. Add thin method wrappers so both styles work.

**Files:**
- Modify: `lib/App/Yath/Schema/DBIC.pm`
- Modify: `t/unit/App/Yath/Schema/DBIC.t`

- [ ] **Step 1: Extend the failing test**

Add to the bottom of `t/unit/App/Yath/Schema/DBIC.t` (before `done_testing`):

```perl
# Method-form wrappers must also work, since existing consumers call
# $schema->is_postgresql as a method.
{
    local $App::Yath::Schema::DBIC::LOADED = 'PostgreSQL';
    ok(App::Yath::Schema::DBIC->is_postgresql, 'method-form is_postgresql');
    ok(!App::Yath::Schema::DBIC->is_sqlite,    'method-form is_sqlite false');
    is(App::Yath::Schema::DBIC->format_uuid_for_db('x'), 'x', 'method-form format_uuid_for_db');
}
```

- [ ] **Step 2: Run the test to verify the new assertions fail**

```
prove -Ilib t/unit/App/Yath/Schema/DBIC.t
```

Expected: the existing assertions still pass; the three new ones fail with "Too many arguments" or "wrong value" because the bare subs do not currently ignore an invocant.

- [ ] **Step 3: Make the subs tolerate being called as methods**

The simplest fix is to have each `is_*` / helper ignore a leading class invocant. Replace the `sub is_sqlite { ... }` family in `DBIC.pm` with:

```perl
sub is_sqlite     { shift if @_ && !ref($_[0]) && $_[0] && $_[0] =~ /::/; ($App::Yath::Schema::DBIC::LOADED // '') =~ m/SQLite/     ? 1 : 0 }
sub is_postgresql { shift if @_ && !ref($_[0]) && $_[0] && $_[0] =~ /::/; ($App::Yath::Schema::DBIC::LOADED // '') =~ m/PostgreSQL/ ? 1 : 0 }
sub is_mariadb    { shift if @_ && !ref($_[0]) && $_[0] && $_[0] =~ /::/; ($App::Yath::Schema::DBIC::LOADED // '') =~ m/MariaDB/    ? 1 : 0 }
sub is_percona    { shift if @_ && !ref($_[0]) && $_[0] && $_[0] =~ /::/; ($App::Yath::Schema::DBIC::LOADED // '') =~ m/Percona/    ? 1 : 0 }
```

Apply the same `shift if ...` idiom at the top of `is_mysql`, `can_store_null_character`, `format_uuid_for_db`, and `format_uuid_for_app`.

This is ugly but one line per sub. The alternative — defining separate `sub is_postgresql { ... }` package methods that delegate to the bare subs — requires renaming the bare subs, which would complicate exports. Accept the ugliness.

- [ ] **Step 4: Run the test to verify everything passes**

```
prove -Ilib t/unit/App/Yath/Schema/DBIC.t
```

Expected: all subtests pass.

- [ ] **Step 5: Commit**

```
git add lib/App/Yath/Schema/DBIC.pm t/unit/App/Yath/Schema/DBIC.t
git commit -m "feat(schema): support both sub- and method-form helper calls"
```

---

### Task 3: Create `App::Yath::Schema::DBIC::ResultBase`

This is a straight copy of the existing `App::Yath::Schema::ResultBase` under the new namespace. It must exist before any Result class can `use parent`.

**Files:**
- Create: `lib/App/Yath/Schema/DBIC/ResultBase.pm`

- [ ] **Step 1: Create the file**

```perl
package App::Yath::Schema::DBIC::ResultBase;
use strict;
use warnings;

our $VERSION = '2.000011';

use parent 'DBIx::Class::Core';

*get_all_fields = __PACKAGE__->can('get_inflated_columns');

sub TO_JSON {
    my $self = shift;
    my %cols = $self->get_all_fields;
    return \%cols;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC::ResultBase - Base class for unified DBIC Result modules.

=cut
```

- [ ] **Step 2: Syntax check**

```
perl -Ilib -c lib/App/Yath/Schema/DBIC/ResultBase.pm
```

Expected: `lib/App/Yath/Schema/DBIC/ResultBase.pm syntax OK`.

- [ ] **Step 3: Commit**

```
git add lib/App/Yath/Schema/DBIC/ResultBase.pm
git commit -m "feat(schema): add App::Yath::Schema::DBIC::ResultBase"
```

---

### Task 4: Create `App::Yath::Schema::DBIC::ResultSet`

Direct copy of the existing `App::Yath::Schema::ResultSet` under the new namespace. Before starting, read the existing file and preserve its content.

**Files:**
- Read: `lib/App/Yath/Schema/ResultSet.pm`
- Create: `lib/App/Yath/Schema/DBIC/ResultSet.pm`

- [ ] **Step 1: Read the existing file**

```
cat lib/App/Yath/Schema/ResultSet.pm
```

- [ ] **Step 2: Create the new file**

Copy the content verbatim into `lib/App/Yath/Schema/DBIC/ResultSet.pm`, changing only:
- `package App::Yath::Schema::ResultSet;` → `package App::Yath::Schema::DBIC::ResultSet;`
- Any reference to `App::Yath::Schema::Result::` inside the body → `App::Yath::Schema::DBIC::Result::`
- Any reference to `$App::Yath::Schema::LOADED` → `$App::Yath::Schema::DBIC::LOADED`

Do not change logic. Do not reformat.

- [ ] **Step 3: Syntax check**

```
perl -Ilib -c lib/App/Yath/Schema/DBIC/ResultSet.pm
```

Expected: syntax OK.

- [ ] **Step 4: Commit**

```
git add lib/App/Yath/Schema/DBIC/ResultSet.pm
git commit -m "feat(schema): add App::Yath::Schema::DBIC::ResultSet"
```

---

## Phase 2 — The regen helper library (parse / merge / emit / splice)

These helpers go under `author_tools/lib/Yath/Regen/DBIC/` so they are author-only (never shipped to CPAN) and can be unit-tested in isolation. Each helper is a pure function.

### Task 5: Fixture — capture a real DBIC::Loader dump

Before writing parsers, capture real loader output to use as test fixtures. Without this, later tests are writing against a hypothetical format.

**Files:**
- Create: `author_tools/t/fixtures/loader-sample-sqlite-User.pm`
- Create: `author_tools/t/fixtures/loader-sample-postgresql-User.pm`

- [ ] **Step 1: Generate fixtures by running the existing regen against two backends**

Run the current (un-modified) `regen_schema.pl` against SQLite and PostgreSQL only. It dumps into `./tmp/SQLite/` and `./tmp/PostgreSQL/`. After the run, copy the dumped `User` Result class to the fixtures directory:

```
mkdir -p author_tools/t/fixtures
cp tmp/SQLite/App/Yath/Schema/Result/User.pm     author_tools/t/fixtures/loader-sample-sqlite-User.pm
cp tmp/PostgreSQL/App/Yath/Schema/Result/User.pm author_tools/t/fixtures/loader-sample-postgresql-User.pm
```

If running `regen_schema.pl` is not practical at this moment (e.g., DBs not available), use the content of `lib/App/Yath/Schema/SQLite/User.pm` and `lib/App/Yath/Schema/PostgreSQL/User.pm` as fixtures instead — they are the committed output of exactly this tool and will parse identically.

- [ ] **Step 2: Commit the fixtures**

```
git add author_tools/t/fixtures/loader-sample-sqlite-User.pm author_tools/t/fixtures/loader-sample-postgresql-User.pm
git commit -m "test(regen): add loader output fixtures"
```

---

### Task 6: Parser — `Yath::Regen::DBIC::Parser::parse_dump`

Parses one loader-dumped Result module into a structured hashref. Pure function, tested against the fixtures.

**Files:**
- Create: `author_tools/lib/Yath/Regen/DBIC/Parser.pm`
- Create: `author_tools/t/parser.t`

**Parsed structure:**

```perl
{
    package => 'App::Yath::Schema::Result::User',
    table   => 'users',
    components => ['InflateColumn::DateTime', 'InflateColumn::Serializer', 'InflateColumn::Serializer::JSON'],
    columns => [                    # ordered list, not hash
        { name => 'user_id',  spec => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 } },
        { name => 'username', spec => { data_type => 'varchar', size => 64, is_nullable => 0 } },
        # ...
    ],
    primary_key         => ['user_id'],
    unique_constraints  => [ { name => 'username_unique', cols => ['username'] } ],
    relationships       => [
        {
            kind    => 'has_many',     # 'has_many' | 'might_have' | 'belongs_to'
            name    => 'api_keys',
            target  => 'App::Yath::Schema::Result::ApiKey',
            cond    => { "foreign.user_id" => "self.user_id" },
            attrs   => { cascade_copy => 0, cascade_delete => 1 },
        },
        # ...
    ],
}
```

- [ ] **Step 1: Write the failing test**

Create `author_tools/t/parser.t`:

```perl
use strict;
use warnings;
use Test2::V0;

use lib 'author_tools/lib';
use Yath::Regen::DBIC::Parser qw/parse_dump/;

my $sqlite_path = 'author_tools/t/fixtures/loader-sample-sqlite-User.pm';
open(my $fh, '<', $sqlite_path) or die "open $sqlite_path: $!";
my $content = do { local $/; <$fh> };
close $fh;

my $parsed = parse_dump($content);

is($parsed->{package}, 'App::Yath::Schema::Result::User', 'package name parsed');
is($parsed->{table},   'users',                            'table name parsed');

is(
    $parsed->{components},
    [
        "InflateColumn::DateTime",
        "InflateColumn::Serializer",
        "InflateColumn::Serializer::JSON",
    ],
    'components parsed',
);

# First column is user_id with integer/auto_increment.
is($parsed->{columns}[0]{name}, 'user_id', 'first column name');
is(
    $parsed->{columns}[0]{spec}{data_type},
    'integer',
    'user_id data_type (SQLite)',
);
is($parsed->{columns}[0]{spec}{is_auto_increment}, 1, 'user_id is_auto_increment');

is($parsed->{primary_key}, ['user_id'], 'primary key parsed');

ok(
    (grep { $_->{name} eq 'username_unique' } @{ $parsed->{unique_constraints} }),
    'username_unique constraint parsed',
);

my ($api_keys_rel) = grep { $_->{name} eq 'api_keys' } @{ $parsed->{relationships} };
ok($api_keys_rel, 'api_keys relationship parsed');
is($api_keys_rel->{kind},   'has_many', 'api_keys kind');
is($api_keys_rel->{target}, 'App::Yath::Schema::Result::ApiKey', 'api_keys target');

done_testing;
```

- [ ] **Step 2: Run to verify it fails**

```
prove -Iauthor_tools/lib author_tools/t/parser.t
```

Expected: fails with "Can't locate Yath/Regen/DBIC/Parser.pm".

- [ ] **Step 3: Implement the parser**

Create `author_tools/lib/Yath/Regen/DBIC/Parser.pm`. The parser evaluates the file's Perl source in a sandboxed package that captures every `__PACKAGE__->method(...)` call. This is simpler and more reliable than a hand-rolled line parser because the loader output is syntactically clean Perl we just generated.

```perl
package Yath::Regen::DBIC::Parser;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw/parse_dump/;

sub parse_dump {
    my ($content) = @_;

    my ($package) = $content =~ m/^\s*package\s+([\w:]+)\s*;/m;
    die "parse_dump: could not find package declaration\n" unless $package;

    my $captured = {
        package            => $package,
        components         => [],
        columns            => [],
        primary_key        => [],
        unique_constraints => [],
        relationships      => [],
        table              => undef,
    };

    # Build a sandbox package whose methods accumulate into $captured.
    my $sandbox = 'Yath::Regen::DBIC::Parser::_Sandbox' . (int(rand(2**31)));
    no strict 'refs';
    *{ "${sandbox}::load_components" } = sub { shift; push @{ $captured->{components} }, @_ };
    *{ "${sandbox}::table" }           = sub { shift; $captured->{table} = $_[0] };
    *{ "${sandbox}::add_columns" }     = sub {
        shift;
        my @args = @_;
        while (@args) {
            my $name = shift @args;
            my $spec = shift @args;
            push @{ $captured->{columns} }, { name => $name, spec => $spec };
        }
    };
    *{ "${sandbox}::set_primary_key" } = sub { shift; $captured->{primary_key} = [@_] };
    *{ "${sandbox}::add_unique_constraint" } = sub {
        shift;
        my ($name, $cols) = @_;
        push @{ $captured->{unique_constraints} }, { name => $name, cols => [@$cols] };
    };
    for my $kind (qw/has_many might_have belongs_to has_one/) {
        *{ "${sandbox}::${kind}" } = sub {
            shift;
            my ($name, $target, $cond, $attrs) = @_;
            push @{ $captured->{relationships} }, {
                kind   => $kind,
                name   => $name,
                target => $target,
                cond   => $cond,
                attrs  => $attrs // {},
            };
        };
    }
    use strict 'refs';

    # Rewrite the file's package + parent so the sandbox runs with our stubs.
    my $munged = $content;
    $munged =~ s/^\s*package\s+[\w:]+\s*;/package $sandbox;/m;
    $munged =~ s/use\s+parent\s+[^;]+;//;
    $munged =~ s/use\s+base\s+[^;]+;//;
    # Strip the trailing POD block so eval doesn't choke.
    $munged =~ s/^__END__\s*$.*//ms;

    my $ok = eval $munged;
    if (!$ok) {
        die "parse_dump eval failed for $package: $@\n";
    }

    return $captured;
}

1;
```

- [ ] **Step 4: Run the test to verify it passes**

```
prove -Iauthor_tools/lib author_tools/t/parser.t
```

Expected: all subtests pass. If it fails on the username column's `data_type` (e.g. `varchar` vs `text`), adjust the fixture expectations — both are valid.

- [ ] **Step 5: Commit**

```
git add author_tools/lib/Yath/Regen/DBIC/Parser.pm author_tools/t/parser.t
git commit -m "feat(regen): add loader-dump parser"
```

---

### Task 7: Merger — `Yath::Regen::DBIC::Merger::merge_backends`

Merges parsed structures from all 5 backends into one unified spec with branching markers where backends disagree.

**Files:**
- Create: `author_tools/lib/Yath/Regen/DBIC/Merger.pm`
- Create: `author_tools/t/merger.t`

**Merged structure:** same shape as the parser output, except column `spec` values can be one of:
- a plain scalar/arrayref/hashref — same value across all backends
- a `Yath::Regen::DBIC::Branch->new(per_backend => { SQLite => ..., PostgreSQL => ..., ... })` blessed object representing disagreement

The `Branch` object is a thin wrapper the emitter recognizes.

- [ ] **Step 1: Write the failing test**

Create `author_tools/t/merger.t`:

```perl
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

# Case 1: all backends identical — no branches.
{
    my $spec = mk(columns => [
        ['foo_id',  { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 }],
        ['name',    { data_type => 'varchar', size => 64, is_nullable => 0 }],
    ]);
    my $merged = merge_backends(
        SQLite     => $spec,
        PostgreSQL => $spec,
        MySQL      => $spec,
        MariaDB    => $spec,
        Percona    => $spec,
    );
    is($merged->{columns}[0]{spec}{data_type}, 'integer', 'identical across backends: plain value');
    ok(!ref $merged->{columns}[0]{spec}{data_type} || ref $merged->{columns}[0]{spec}{data_type} ne 'Yath::Regen::DBIC::Branch', 'not branched');
}

# Case 2: data_type differs between SQLite and the rest.
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

done_testing;
```

- [ ] **Step 2: Run the test to verify it fails**

```
prove -Iauthor_tools/lib author_tools/t/merger.t
```

Expected: fails, modules do not exist.

- [ ] **Step 3: Implement `Yath::Regen::DBIC::Branch`**

Create `author_tools/lib/Yath/Regen/DBIC/Branch.pm`:

```perl
package Yath::Regen::DBIC::Branch;
use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    return bless { per_backend => $args{per_backend} }, $class;
}

sub per_backend { $_[0]->{per_backend} }

sub value_for {
    my ($self, $backend) = @_;
    return $self->{per_backend}{$backend};
}

# Returns a list of [backend_set => value] pairs, grouped so identical values
# share a set. E.g. { SQLite => 'integer', PG => 'bigint', MySQL => 'bigint' }
# returns ([['PostgreSQL','MySQL'], 'bigint'], [['SQLite'], 'integer']).
sub grouped {
    my ($self) = @_;
    my %by_value;
    for my $backend (sort keys %{ $self->{per_backend} }) {
        my $v = $self->{per_backend}{$backend};
        my $key = defined $v ? (ref $v ? _freeze($v) : "s:$v") : 'u:';
        push @{ $by_value{$key}{backends} }, $backend;
        $by_value{$key}{value} = $v;
    }
    return [
        map { [ $by_value{$_}{backends}, $by_value{$_}{value} ] }
        sort keys %by_value
    ];
}

sub _freeze {
    my ($v) = @_;
    # Shallow freeze sufficient for column-spec scalars/hashes.
    require Storable;
    return Storable::freeze(\$v);
}

1;
```

- [ ] **Step 4: Implement `Yath::Regen::DBIC::Merger`**

Create `author_tools/lib/Yath/Regen/DBIC/Merger.pm`:

```perl
package Yath::Regen::DBIC::Merger;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw/merge_backends/;

use Yath::Regen::DBIC::Branch;

my @BACKENDS_ORDER = qw/SQLite PostgreSQL MySQL MariaDB Percona/;

sub merge_backends {
    my %by_backend = @_;
    my @backends   = grep { exists $by_backend{$_} } @BACKENDS_ORDER;
    die "merge_backends: need all 5 backends\n" unless @backends == @BACKENDS_ORDER;

    my $ref = $by_backend{SQLite};

    # Column presence check: every backend must have the same set, same order.
    my $ref_cols = [ map { $_->{name} } @{ $ref->{columns} } ];
    for my $b (@backends) {
        my $cols = [ map { $_->{name} } @{ $by_backend{$b}{columns} } ];
        die "column presence mismatch between SQLite and $b\n"
            unless _same_list($ref_cols, $cols);
    }

    my @merged_columns;
    for my $i (0 .. $#{ $ref->{columns} }) {
        my $name = $ref->{columns}[$i]{name};
        my %spec_per_backend;
        my %keys;
        for my $b (@backends) {
            my $spec = $by_backend{$b}{columns}[$i]{spec};
            $spec_per_backend{$b} = $spec;
            $keys{$_}++ for keys %$spec;
        }

        my %merged_spec;
        for my $key (keys %keys) {
            my %per_backend = map { $_ => $spec_per_backend{$_}{$key} } @backends;
            if (_all_same(values %per_backend)) {
                $merged_spec{$key} = $per_backend{SQLite};
            }
            else {
                $merged_spec{$key} = Yath::Regen::DBIC::Branch->new(per_backend => \%per_backend);
            }
        }

        push @merged_columns, { name => $name, spec => \%merged_spec };
    }

    # Primary key, unique constraints, relationships: require agreement.
    for my $field (qw/primary_key unique_constraints relationships table components/) {
        for my $b (@backends) {
            die "$field mismatch between SQLite and $b for $ref->{package}\n"
                unless _deep_equal($ref->{$field}, $by_backend{$b}{$field});
        }
    }

    return {
        package            => $ref->{package},
        table              => $ref->{table},
        components         => $ref->{components},
        columns            => \@merged_columns,
        primary_key        => $ref->{primary_key},
        unique_constraints => $ref->{unique_constraints},
        relationships      => $ref->{relationships},
    };
}

sub _same_list {
    my ($a, $b) = @_;
    return 0 unless @$a == @$b;
    for my $i (0 .. $#$a) {
        return 0 unless $a->[$i] eq $b->[$i];
    }
    return 1;
}

sub _all_same {
    my @vals = @_;
    my $ref  = _canon($vals[0]);
    for my $v (@vals) {
        return 0 unless _canon($v) eq $ref;
    }
    return 1;
}

sub _canon {
    my ($v) = @_;
    return 'u:' unless defined $v;
    return 's:' . $v unless ref $v;
    require Storable;
    local $Storable::canonical = 1;
    return 'r:' . Storable::freeze(\$v);
}

sub _deep_equal {
    my ($a, $b) = @_;
    return _canon($a) eq _canon($b);
}

1;
```

**Note:** The relationship and unique-constraint equality requirement is strict. If in practice a backend adds an auto-generated constraint name that differs from SQLite's (MySQL does this), the merger will die. If that happens during the real migration, relax the equality in this function to compare canonical forms that strip generated names. Document the relaxation in the commit message.

- [ ] **Step 5: Run the test to verify it passes**

```
prove -Iauthor_tools/lib author_tools/t/merger.t
```

Expected: all subtests pass.

- [ ] **Step 6: Commit**

```
git add author_tools/lib/Yath/Regen/DBIC/Branch.pm author_tools/lib/Yath/Regen/DBIC/Merger.pm author_tools/t/merger.t
git commit -m "feat(regen): add cross-backend merger"
```

---

### Task 8: Emitter — `Yath::Regen::DBIC::Emitter::emit_result_body`

Takes a merged spec and produces the Perl source that goes between the `BEGIN GENERATED` and `END GENERATED` markers.

**Files:**
- Create: `author_tools/lib/Yath/Regen/DBIC/Emitter.pm`
- Create: `author_tools/t/emitter.t`

- [ ] **Step 1: Write the failing test**

Create `author_tools/t/emitter.t`:

```perl
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
like($out2, qr/is_postgresql|is_sqlite|is_mysql/, 'branched column emits helper call');
like($out2, qr/bigint/, 'bigint value present');
like($out2, qr/integer/, 'integer value present');

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

done_testing;
```

- [ ] **Step 2: Run to verify it fails**

```
prove -Iauthor_tools/lib author_tools/t/emitter.t
```

Expected: fails, module does not exist.

- [ ] **Step 3: Implement the emitter**

Create `author_tools/lib/Yath/Regen/DBIC/Emitter.pm`:

```perl
package Yath::Regen::DBIC::Emitter;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw/emit_result_body/;

use Data::Dumper ();

use Yath::Regen::DBIC::Branch;

sub emit_result_body {
    my ($spec) = @_;
    my @lines;

    if (@{ $spec->{components} }) {
        push @lines, "__PACKAGE__->load_components(";
        for my $c (@{ $spec->{components} }) {
            push @lines, qq{    "$c",};
        }
        push @lines, ");";
    }

    push @lines, qq{__PACKAGE__->table("$spec->{table}");};
    push @lines, '__PACKAGE__->add_columns(';
    for my $col (@{ $spec->{columns} }) {
        push @lines, qq{    "$col->{name}",};
        push @lines, _emit_column_hash($col->{spec});
    }
    push @lines, ');';

    if (@{ $spec->{primary_key} }) {
        my $pk = join ', ', map { qq{"$_"} } @{ $spec->{primary_key} };
        push @lines, "__PACKAGE__->set_primary_key($pk);";
    }

    for my $uc (@{ $spec->{unique_constraints} }) {
        my $cols = join ', ', map { qq{"$_"} } @{ $uc->{cols} };
        push @lines, qq{__PACKAGE__->add_unique_constraint("$uc->{name}", [$cols]);};
    }

    for my $rel (@{ $spec->{relationships} }) {
        push @lines, _emit_relationship($rel);
    }

    return join("\n", @lines) . "\n";
}

sub _emit_column_hash {
    my ($spec) = @_;
    my @lines = ('    {');
    for my $key (sort keys %$spec) {
        my $val = $spec->{$key};
        if (ref($val) eq 'Yath::Regen::DBIC::Branch') {
            push @lines, "        $key => " . _emit_branch($val) . ",";
        }
        else {
            push @lines, "        $key => " . _emit_scalar($val) . ",";
        }
    }
    push @lines, '    },';
    return @lines;
}

sub _emit_scalar {
    my ($v) = @_;
    return 'undef' unless defined $v;
    if (ref $v eq 'ARRAY') {
        return '[' . join(', ', map { _emit_scalar($_) } @$v) . ']';
    }
    if (ref $v eq 'HASH') {
        my @pairs;
        for my $k (sort keys %$v) {
            push @pairs, qq{"$k" => } . _emit_scalar($v->{$k});
        }
        return '{ ' . join(', ', @pairs) . ' }';
    }
    if (ref $v eq 'SCALAR') {
        # Literal SQL reference, e.g. \"null".
        return '\\' . _emit_scalar($$v);
    }
    # Numeric?
    return $v if $v =~ /\A-?\d+(?:\.\d+)?\z/;
    my $quoted = $v;
    $quoted =~ s/\\/\\\\/g;
    $quoted =~ s/"/\\"/g;
    return qq{"$quoted"};
}

sub _emit_branch {
    my ($branch) = @_;
    my $groups = $branch->grouped;

    # Two groups → single ternary. Three+ → nested ternary.
    my @group_exprs;
    for my $g (@$groups) {
        my ($backends, $value) = @$g;
        my $cond = _backends_condition($backends);
        push @group_exprs, [ $cond, _emit_scalar($value) ];
    }

    # Build a right-associative ternary chain, last group as the else.
    my $chain = $group_exprs[-1][1];
    for (my $i = $#group_exprs - 1; $i >= 0; $i--) {
        my ($cond, $val) = @{ $group_exprs[$i] };
        $chain = "$cond ? $val : $chain";
    }
    return $chain;
}

sub _backends_condition {
    my ($backends) = @_;
    my @tests;
    for my $b (@$backends) {
        push @tests, 'is_sqlite()'     if $b eq 'SQLite';
        push @tests, 'is_postgresql()' if $b eq 'PostgreSQL';
        push @tests, 'is_mysql()'      if $b eq 'MySQL';
        push @tests, 'is_mariadb()'    if $b eq 'MariaDB';
        push @tests, 'is_percona()'    if $b eq 'Percona';
    }
    return @tests == 1 ? $tests[0] : '(' . join(' || ', @tests) . ')';
}

sub _emit_relationship {
    my ($rel) = @_;
    my $target = $rel->{target};
    $target =~ s/^App::Yath::Schema::Result::/App::Yath::Schema::DBIC::Result::/;

    my $cond_src  = _emit_scalar($rel->{cond});
    my $attrs_src = $rel->{attrs} && %{ $rel->{attrs} }
        ? ', ' . _emit_scalar($rel->{attrs})
        : '';

    return sprintf(
        qq{__PACKAGE__->%s(\n    "%s",\n    "%s",\n    %s%s,\n);},
        $rel->{kind},
        $rel->{name},
        $target,
        $cond_src,
        $attrs_src,
    );
}

1;
```

- [ ] **Step 4: Run the test to verify it passes**

```
prove -Iauthor_tools/lib author_tools/t/emitter.t
```

Expected: all subtests pass.

- [ ] **Step 5: Commit**

```
git add author_tools/lib/Yath/Regen/DBIC/Emitter.pm author_tools/t/emitter.t
git commit -m "feat(regen): add emitter with branch-aware ternary output"
```

---

### Task 9: Splicer — `Yath::Regen::DBIC::Splicer::splice_generated`

Given existing file content and new generated body text, replaces the region between markers and returns the new file content. Preserves the custom tail byte-for-byte. If markers are absent, dies with the file path.

**Files:**
- Create: `author_tools/lib/Yath/Regen/DBIC/Splicer.pm`
- Create: `author_tools/t/splicer.t`

- [ ] **Step 1: Write the failing test**

Create `author_tools/t/splicer.t`:

```perl
use strict;
use warnings;
use Test2::V0;

use lib 'author_tools/lib';
use Yath::Regen::DBIC::Splicer qw/splice_generated BEGIN_MARKER END_MARKER/;

my $begin = BEGIN_MARKER();
my $end   = END_MARKER();

my $existing = <<"FILE";
package App::Yath::Schema::DBIC::Result::Foo;
use strict;
use warnings;
use parent 'App::Yath::Schema::DBIC::ResultBase';

$begin
__PACKAGE__->table("old_table");
$end

sub custom_method { return "preserved" }

1;
FILE

my $new_body = qq{__PACKAGE__->table("new_table");\n__PACKAGE__->add_columns("foo_id", { data_type => "integer" });};

my $spliced = splice_generated($existing, $new_body, file => 'Foo.pm');

like($spliced, qr/\Qnew_table\E/,            'new body inserted');
unlike($spliced, qr/\Qold_table\E/,          'old body removed');
like($spliced, qr/sub custom_method/,        'custom tail preserved');
like($spliced, qr/\Q$begin\E/,               'begin marker preserved');
like($spliced, qr/\Q$end\E/,                 'end marker preserved');
like($spliced, qr/\A\s*package/,             'header preserved');

# Missing markers should die with the file path.
my $bad = "package Foo;\nuse strict;\n1;\n";
like(
    dies { splice_generated($bad, $new_body, file => 'Bad.pm') },
    qr/Bad\.pm.*marker/i,
    'missing markers die with file path',
);

done_testing;
```

- [ ] **Step 2: Run to verify it fails**

```
prove -Iauthor_tools/lib author_tools/t/splicer.t
```

Expected: fails, module does not exist.

- [ ] **Step 3: Implement the splicer**

Create `author_tools/lib/Yath/Regen/DBIC/Splicer.pm`:

```perl
package Yath::Regen::DBIC::Splicer;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw/splice_generated BEGIN_MARKER END_MARKER/;

use constant BEGIN_MARKER => '# >>> BEGIN GENERATED - DO NOT EDIT <<<';
use constant END_MARKER   => '# >>> END GENERATED <<<';

sub splice_generated {
    my ($content, $new_body, %opts) = @_;
    my $file = $opts{file} // '<unknown>';

    my $begin = BEGIN_MARKER;
    my $end   = END_MARKER;

    my $begin_idx = index($content, $begin);
    my $end_idx   = index($content, $end);

    if ($begin_idx < 0 || $end_idx < 0 || $end_idx < $begin_idx) {
        die "splice_generated: $file missing BEGIN/END marker pair\n";
    }

    my $before = substr($content, 0, $begin_idx + length($begin));
    my $after  = substr($content, $end_idx);

    return $before . "\n" . $new_body . "\n" . $after;
}

1;
```

- [ ] **Step 4: Run the test to verify it passes**

```
prove -Iauthor_tools/lib author_tools/t/splicer.t
```

Expected: all subtests pass.

- [ ] **Step 5: Commit**

```
git add author_tools/lib/Yath/Regen/DBIC/Splicer.pm author_tools/t/splicer.t
git commit -m "feat(regen): add marker-based splicer"
```

---

### Task 10: Fresh-file writer — `Yath::Regen::DBIC::Writer::write_new_result`

Writes a brand-new Result module file with the correct header, markers, empty custom tail, and POD. Used by regen when a Result class has no existing file.

**Files:**
- Create: `author_tools/lib/Yath/Regen/DBIC/Writer.pm`
- Create: `author_tools/t/writer.t`

- [ ] **Step 1: Write the failing test**

Create `author_tools/t/writer.t`:

```perl
use strict;
use warnings;
use Test2::V0;

use lib 'author_tools/lib';
use Yath::Regen::DBIC::Writer qw/build_new_result/;

my $out = build_new_result(
    package => 'App::Yath::Schema::DBIC::Result::Foo',
    body    => qq{__PACKAGE__->table("foos");\n},
);

like($out, qr/^package App::Yath::Schema::DBIC::Result::Foo;/m, 'package line');
like($out, qr/^use utf8;/m,                                     'use utf8');
like($out, qr/^use strict;/m,                                   'use strict');
like($out, qr/^use warnings;/m,                                 'use warnings');
like($out, qr/^use parent 'App::Yath::Schema::DBIC::ResultBase';/m, 'parent class');
like($out, qr/use App::Yath::Schema::DBIC qw\/is_sqlite/, 'imports helpers');
like($out, qr/# >>> BEGIN GENERATED - DO NOT EDIT <<</,          'begin marker');
like($out, qr/# >>> END GENERATED <<</,                          'end marker');
like($out, qr/__PACKAGE__->table\("foos"\)/,                     'body inserted');
like($out, qr/\n1;\n/,                                           'trailing 1;');
like($out, qr/__END__/,                                          'POD started');

done_testing;
```

- [ ] **Step 2: Run to verify it fails**

```
prove -Iauthor_tools/lib author_tools/t/writer.t
```

- [ ] **Step 3: Implement the writer**

Create `author_tools/lib/Yath/Regen/DBIC/Writer.pm`:

```perl
package Yath::Regen::DBIC::Writer;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw/build_new_result/;

use Yath::Regen::DBIC::Splicer qw/BEGIN_MARKER END_MARKER/;

sub build_new_result {
    my (%args) = @_;
    my $pkg     = $args{package} // die "package required\n";
    my $body    = $args{body}    // die "body required\n";
    my $short   = $pkg =~ m/::(\w+)$/ ? $1 : $pkg;
    my $version = $args{version} // '2.000011';

    my $begin = BEGIN_MARKER;
    my $end   = END_MARKER;

    return <<"EOT";
use utf8;
package $pkg;
our \$VERSION = '$version';

use strict;
use warnings;
use parent 'App::Yath::Schema::DBIC::ResultBase';

use App::Yath::Schema::DBIC qw/is_sqlite is_postgresql is_mysql is_mariadb is_percona/;

$begin
# Regenerated by author_tools/regen_schema.pl from share/schema/*.sql
$body
$end

# Custom methods live below; regen_schema.pl never touches this region.

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

$pkg - Unified DBIC result class for $short.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist\@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7\@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
EOT
}

1;
```

- [ ] **Step 4: Run the test to verify it passes**

```
prove -Iauthor_tools/lib author_tools/t/writer.t
```

- [ ] **Step 5: Commit**

```
git add author_tools/lib/Yath/Regen/DBIC/Writer.pm author_tools/t/writer.t
git commit -m "feat(regen): add fresh-file writer for unified Result modules"
```

---

### Task 11: Overlay extractor — `Yath::Regen::DBIC::OverlayMigrator`

Reads an existing `Overlay/<Name>.pm` and returns the custom body (everything that should go into the custom tail of the new unified file). Used only during the one-shot `--migrate` run.

**Files:**
- Create: `author_tools/lib/Yath/Regen/DBIC/OverlayMigrator.pm`
- Create: `author_tools/t/overlay_migrator.t`
- Create: `author_tools/t/fixtures/overlay-sample-User.pm` (copy of current `lib/App/Yath/Schema/Overlay/User.pm`)

- [ ] **Step 1: Copy the overlay fixture**

```
cp lib/App/Yath/Schema/Overlay/User.pm author_tools/t/fixtures/overlay-sample-User.pm
```

- [ ] **Step 2: Write the failing test**

Create `author_tools/t/overlay_migrator.t`:

```perl
use strict;
use warnings;
use Test2::V0;

use lib 'author_tools/lib';
use Yath::Regen::DBIC::OverlayMigrator qw/extract_custom_tail/;

my $path = 'author_tools/t/fixtures/overlay-sample-User.pm';
open(my $fh, '<', $path) or die "open: $!";
my $content = do { local $/; <$fh> };
close $fh;

my $tail = extract_custom_tail($content);

# The extracted tail should preserve the verify_password/set_password/gen_salt
# subs and the use statements for bcrypt/uuid, but drop the two `package`
# declarations from the overlay.
like($tail,   qr/sub verify_password/,                       'verify_password preserved');
like($tail,   qr/sub set_password/,                          'set_password preserved');
like($tail,   qr/sub gen_salt/,                              'gen_salt preserved');
like($tail,   qr/use Crypt::Eksblowfish::Bcrypt/,            'bcrypt use preserved');
like($tail,   qr/use Test2::Util::UUID/,                     'UUID use preserved');
unlike($tail, qr/^\s*package\s+App::Yath::Schema::Overlay/m, 'overlay package dropped');
unlike($tail, qr/^\s*package\s+App::Yath::Schema::Result/m,  'secondary package dropped');
unlike($tail, qr/confess\s+"You must first load/,            'LOADED guard dropped');
unlike($tail, qr/__END__|=pod/,                              'POD dropped');

done_testing;
```

- [ ] **Step 3: Run to verify it fails**

```
prove -Iauthor_tools/lib author_tools/t/overlay_migrator.t
```

- [ ] **Step 4: Implement the migrator**

Create `author_tools/lib/Yath/Regen/DBIC/OverlayMigrator.pm`:

```perl
package Yath::Regen::DBIC::OverlayMigrator;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw/extract_custom_tail/;

sub extract_custom_tail {
    my ($content) = @_;

    # Trim POD.
    $content =~ s/^__END__\b.*//ms;

    # Drop package declarations (both main and secondary-package form).
    $content =~ s/^\s*package\s+App::Yath::Schema::Overlay::\w+\s*;\s*//mg;
    $content =~ s/^\s*package\s*\n\s*App::Yath::Schema::Result::\w+\s*;\s*//mg;
    $content =~ s/^\s*package\s+App::Yath::Schema::Result::\w+\s*;\s*//mg;

    # Drop version assignment if present.
    $content =~ s/^\s*our\s+\$VERSION\s*=\s*'[^']+'\s*;\s*$//mg;

    # Drop the LOADED guard block.
    $content =~ s/
        ^\s*use\s+Carp\s+qw/\S+\/;\s*$\n?     # optional use Carp
    //mx;
    $content =~ s/
        ^\s*confess\s+"You\s+must\s+first\s+load[^"]*"\s*
        \s*unless\s+\$App::Yath::Schema::LOADED\s*;\s*$\n?
    //mx;

    # Drop `use Class::C3;` — superseded in the unified class.
    $content =~ s/^\s*use\s+Class::C3\s*;\s*$\n?//mg;

    # Drop strict/warnings/utf8 — inherited from the unified module header.
    $content =~ s/^\s*use\s+(?:strict|warnings|utf8)\s*;\s*$\n?//mg;

    # Trim trailing '1;' — the unified file provides its own.
    $content =~ s/^\s*1\s*;\s*$\n?//m;

    # Collapse leading blank lines.
    $content =~ s/\A(\s*\n)+//;

    return $content;
}

1;
```

**Note:** The regex cleanup is intentionally conservative. If any overlay file has a shape the regexes do not match (e.g. an extra `use` line inside the guard block), the extraction will leave stray code in the tail. Phase 4's hand-verification step will catch these. If a common pattern emerges, extend the regexes.

- [ ] **Step 5: Run the test to verify it passes**

```
prove -Iauthor_tools/lib author_tools/t/overlay_migrator.t
```

- [ ] **Step 6: Commit**

```
git add author_tools/lib/Yath/Regen/DBIC/OverlayMigrator.pm author_tools/t/overlay_migrator.t author_tools/t/fixtures/overlay-sample-User.pm
git commit -m "feat(regen): add overlay-to-tail migrator"
```

---

## Phase 3 — Rewrite `regen_schema.pl`

### Task 12: Rewrite `regen_schema.pl` to produce unified layout

This task replaces the current script end-to-end. Read the existing script first to preserve the driver-setup, QuickDB-spin-up, and `make_schema_at` phases — the new script keeps those and only changes what happens after dumping.

**Files:**
- Read: `author_tools/regen_schema.pl` (existing)
- Rewrite: `author_tools/regen_schema.pl`

- [ ] **Step 1: Read the existing script end-to-end**

```
cat author_tools/regen_schema.pl
```

Note: driver list, QuickDB setup, and `make_schema_at` invocation. The new script reuses all of these.

- [ ] **Step 2: Write the new script**

Replace `author_tools/regen_schema.pl` with the following structure (fill in the preserved phases from the existing script):

```perl
#!/usr/bin/env perl
use strict;
use warnings;

use File::Path qw/make_path/;
use File::Temp qw/tempdir/;
use Getopt::Long;

use DBIx::Class::Schema::Loader 'make_schema_at';
use DBIx::QuickDB;

use lib 'author_tools/lib';
use Yath::Regen::DBIC::Parser          qw/parse_dump/;
use Yath::Regen::DBIC::Merger          qw/merge_backends/;
use Yath::Regen::DBIC::Emitter         qw/emit_result_body/;
use Yath::Regen::DBIC::Splicer         qw/splice_generated BEGIN_MARKER END_MARKER/;
use Yath::Regen::DBIC::Writer          qw/build_new_result/;
use Yath::Regen::DBIC::OverlayMigrator qw/extract_custom_tail/;

use App::Yath::Schema::Util qw/qdb_driver dbd_driver format_driver/;

my $schemadir = './share/schema/';
my $libdir    = './lib/App/Yath/Schema/DBIC/Result';
my $overlaydir = './lib/App/Yath/Schema/Overlay';

my $migrate = 0;
GetOptions('migrate' => \$migrate) or die "bad options\n";

my @backends = qw/SQLite PostgreSQL MySQL MariaDB Percona/;

# ----- Phase A: dump each backend into a scratch dir --------------------
my $scratch = tempdir('yath-regen-XXXXXX', DIR => './tmp', CLEANUP => 0);
print "Scratch dir: $scratch\n";

my %dump_dirs;  # backend => "$scratch/<backend>/App/Yath/Schema/Result"
for my $backend (@backends) {
    my $schema_file = "$backend.sql";
    # ... reproduce the existing QuickDB setup + load_sql + fork + make_schema_at
    # logic, dumping into "$scratch/$backend" instead of ./tmp/$backend ...
    # See the existing script's body at author_tools/regen_schema.pl:52-128.
    $dump_dirs{$backend} = "$scratch/$backend/App/Yath/Schema/Result";
}

# ----- Phase B+C: parse + merge -----------------------------------------
my @result_files = do {
    opendir(my $dh, $dump_dirs{SQLite}) or die "open $dump_dirs{SQLite}: $!";
    sort grep { /\.pm$/ } readdir($dh);
};

my %merged_by_name;
for my $file (@result_files) {
    my %parsed;
    for my $backend (@backends) {
        my $path = "$dump_dirs{$backend}/$file";
        open(my $fh, '<', $path) or die "open $path: $!";
        my $content = do { local $/; <$fh> };
        close $fh;
        $parsed{$backend} = parse_dump($content);
    }
    my $merged = merge_backends(%parsed);
    (my $short = $file) =~ s/\.pm$//;
    $merged_by_name{$short} = $merged;
}

# ----- Phase D: emit unified Result files -------------------------------
make_path($libdir);
my %stats = (fresh => 0, updated => 0, preserved_tail => 0, seeded => 0);

for my $short (sort keys %merged_by_name) {
    my $merged = $merged_by_name{$short};
    my $pkg    = "App::Yath::Schema::DBIC::Result::$short";
    my $target = "$libdir/$short.pm";
    my $body   = emit_result_body($merged);

    if (-e $target) {
        open(my $fh, '<', $target) or die "open $target: $!";
        my $existing = do { local $/; <$fh> };
        close $fh;

        my $new_content = splice_generated($existing, $body, file => $target);
        _write_file($target, $new_content);
        $stats{updated}++;
        $stats{preserved_tail}++;
    }
    else {
        my $new_content = build_new_result(package => $pkg, body => $body);

        if ($migrate) {
            my $overlay_path = "$overlaydir/$short.pm";
            if (-e $overlay_path) {
                open(my $fh, '<', $overlay_path) or die "open $overlay_path: $!";
                my $overlay = do { local $/; <$fh> };
                close $fh;
                my $tail = extract_custom_tail($overlay);
                if (length $tail) {
                    # Insert the tail just above the trailing `1;` line.
                    $new_content =~ s/(\n1;\n\n__END__)/\n$tail\n$1/
                        or die "migrate: couldn't find '1;' anchor in $target";
                    $stats{seeded}++;
                }
            }
        }

        _write_file($target, $new_content);
        $stats{fresh}++;
    }
}

# ----- Phase E: emit root + connection modules --------------------------
# Write fully-generated files for:
#   lib/App/Yath/Schema/DBIC.pm     (if not already the final form - see task 13)
#   lib/App/Yath/Schema/DBIC/ResultBase.pm
#   lib/App/Yath/Schema/DBIC/ResultSet.pm
#   lib/App/Yath/Schema/DBIC/SQLite.pm
#   lib/App/Yath/Schema/DBIC/PostgreSQL.pm
#   lib/App/Yath/Schema/DBIC/MySQL.pm
#   lib/App/Yath/Schema/DBIC/MariaDB.pm
#   lib/App/Yath/Schema/DBIC/Percona.pm
#
# The connection modules are nearly identical to today's per-DB top-level files
# under lib/App/Yath/Schema/. Reuse the existing template (see the existing
# regen_schema.pl's heredoc at lines 135-199), changing only:
#   - package name: App::Yath::Schema::DBIC::<Driver>
#   - $LOADED var:   $App::Yath::Schema::DBIC::LOADED
#   - require line: require App::Yath::Schema::DBIC;
_emit_connection_modules(\@backends);

# ----- Phase F: cleanup -------------------------------------------------
# Keep the scratch dir if --keep-scratch, else remove.
unless ($ENV{YATH_REGEN_KEEP_SCRATCH}) {
    system('rm', '-rf', $scratch);
}

print "Regen summary:\n";
print "  fresh:          $stats{fresh}\n";
print "  updated:        $stats{updated}\n";
print "  preserved tail: $stats{preserved_tail}\n";
print "  migrated tail:  $stats{seeded}\n";

sub _write_file {
    my ($path, $content) = @_;
    make_path($path =~ s{/[^/]+$}{}r);
    open(my $fh, '>', $path) or die "write $path: $!";
    print {$fh} $content;
    close $fh;
}

sub _emit_connection_modules {
    # See existing regen_schema.pl:135-199 for the template. Reproduce here
    # with the namespace/variable changes noted above. Returns nothing.
    ...
}
```

**Note:** The `...` (yada-yada) is a placeholder for boilerplate that the engineer must fill in by porting the existing script's connection-module template. This is one of the ~4 places where a mechanical copy-with-edits is cleaner than reproducing verbatim code in a plan.

- [ ] **Step 3: Syntax-check the new script**

```
perl -Iauthor_tools/lib -Ilib -c author_tools/regen_schema.pl
```

Expected: `author_tools/regen_schema.pl syntax OK`.

- [ ] **Step 4: Commit**

```
git add author_tools/regen_schema.pl
git commit -m "refactor(regen): rewrite regen_schema.pl to produce unified layout"
```

---

## Phase 4 — Run the migration

### Task 13: Pre-migration snapshot commit

Before running the migration, commit a "state before migration" marker so `git diff` against it can reveal anything the migration drops.

**Files:** none changed — this is a marker commit only.

- [ ] **Step 1: Confirm a clean working tree for this branch**

```
git status
```

Expected: clean (aside from the unrelated `deplib/` changes).

- [ ] **Step 2: Tag the current commit**

```
git tag pre-dbic-migration
```

- [ ] **Step 3: No commit needed**

The tag is local-only. If the migration goes wrong, reset with `git reset --hard pre-dbic-migration`.

---

### Task 14: Run `regen_schema.pl --migrate`

Runs the new script in migration mode. Requires at least SQLite, PostgreSQL, MySQL, MariaDB, and Percona to be startable via DBIx::QuickDB on the current machine.

**Files:**
- Create: 29 files under `lib/App/Yath/Schema/DBIC/Result/`
- Create: 6 files (`DBIC.pm` if not yet final, plus the 5 connection modules)
- Modify: `lib/App/Yath/Schema/DBIC/ResultBase.pm`, `DBIC/ResultSet.pm` (rewritten by Phase E)

- [ ] **Step 1: Run the migration**

```
perl -Iauthor_tools/lib -Ilib author_tools/regen_schema.pl --migrate
```

Expected output: summary showing `fresh: 29, migrated tail: 29, updated: 0, preserved tail: 0`. If a backend fails to start, the script should die with a clear message — do not proceed until all 5 are working.

- [ ] **Step 2: Inspect what was created**

```
find lib/App/Yath/Schema/DBIC -type f -name '*.pm' | sort
```

Expected: 29 Result files, 5 connection modules, DBIC.pm, DBIC/ResultBase.pm, DBIC/ResultSet.pm.

- [ ] **Step 3: Commit the migration output**

```
git add lib/App/Yath/Schema/DBIC/
git commit -m "feat(schema): migrate DBIC Result classes to unified layout"
```

---

### Task 15: Hand-verify three migrated Result classes

Diff the unified classes against the old per-DB + overlay files to confirm nothing was lost.

**Files read only:**
- `lib/App/Yath/Schema/DBIC/Result/User.pm`
- `lib/App/Yath/Schema/DBIC/Result/ApiKey.pm`
- `lib/App/Yath/Schema/DBIC/Result/Run.pm`
- `lib/App/Yath/Schema/SQLite/User.pm`, `PostgreSQL/User.pm`, `Overlay/User.pm`
- (and the equivalents for ApiKey and Run)

- [ ] **Step 1: Compare User.pm**

For each of `User`, `ApiKey`, `Run`:

1. Read the new `lib/App/Yath/Schema/DBIC/Result/<Name>.pm`.
2. Read all 5 old `lib/App/Yath/Schema/<Driver>/<Name>.pm`.
3. Read `lib/App/Yath/Schema/Overlay/<Name>.pm`.
4. Confirm: every column present in the old files appears in the new file. Every relationship present in the old files appears. Every sub defined in the overlay appears in the new file's custom tail. Every `use` line from the overlay appears in the tail.
5. Confirm: branched columns emit a ternary when the old files differed, and an unconditional value when they agreed.

- [ ] **Step 2: Fix anything wrong**

If a sub or `use` is missing from a tail, extend `OverlayMigrator::extract_custom_tail` regexes and re-run just the migration for affected files (or re-run the whole migration). If a column is wrong, fix the emitter or merger and re-run.

- [ ] **Step 3: Commit any fixes**

```
git add -A
git commit -m "fix(regen): <description of what was fixed>"
```

Only commit once the three hand-verified files are correct.

---

### Task 16: Delete the old schema trees

**Files deleted:**
- `lib/App/Yath/Schema/SQLite/` (directory + 29 files)
- `lib/App/Yath/Schema/PostgreSQL/` (directory + 29 files)
- `lib/App/Yath/Schema/MySQL/` (directory + 29 files)
- `lib/App/Yath/Schema/MariaDB/` (directory + 29 files)
- `lib/App/Yath/Schema/Percona/` (directory + 29 files)
- `lib/App/Yath/Schema/Overlay/` (directory + 29 files)
- `lib/App/Yath/Schema/Result/` (directory + 29 files — old dispatchers)
- `lib/App/Yath/Schema.pm`
- `lib/App/Yath/Schema/ResultBase.pm`
- `lib/App/Yath/Schema/ResultSet.pm`
- `lib/App/Yath/Schema/SQLite.pm`
- `lib/App/Yath/Schema/PostgreSQL.pm`
- `lib/App/Yath/Schema/MySQL.pm`
- `lib/App/Yath/Schema/MariaDB.pm`
- `lib/App/Yath/Schema/Percona.pm`

- [ ] **Step 1: Delete the trees**

```
git rm -r lib/App/Yath/Schema/SQLite \
          lib/App/Yath/Schema/PostgreSQL \
          lib/App/Yath/Schema/MySQL \
          lib/App/Yath/Schema/MariaDB \
          lib/App/Yath/Schema/Percona \
          lib/App/Yath/Schema/Overlay \
          lib/App/Yath/Schema/Result
git rm    lib/App/Yath/Schema.pm \
          lib/App/Yath/Schema/ResultBase.pm \
          lib/App/Yath/Schema/ResultSet.pm \
          lib/App/Yath/Schema/SQLite.pm \
          lib/App/Yath/Schema/PostgreSQL.pm \
          lib/App/Yath/Schema/MySQL.pm \
          lib/App/Yath/Schema/MariaDB.pm \
          lib/App/Yath/Schema/Percona.pm
```

- [ ] **Step 2: Commit**

```
git commit -m "refactor(schema): delete old per-db and overlay trees"
```

After this commit, the codebase will not compile until Phase 5 rewrites the consumers.

---

## Phase 5 — Consumer updates

### Task 17: Rewrite schema-adjacent modules that keep their names

**Files to modify** (each keeps its current name; only its internals change):

- `lib/App/Yath/Schema/Util.pm`
- `lib/App/Yath/Schema/Sync.pm`
- `lib/App/Yath/Schema/Sweeper.pm`
- `lib/App/Yath/Schema/RunProcessor.pm`
- `lib/App/Yath/Schema/Importer.pm`
- `lib/App/Yath/Schema/ImportModes.pm`
- `lib/App/Yath/Schema/Queries.pm`
- `lib/App/Yath/Schema/Config.pm`
- `lib/App/Yath/Schema/DateTimeFormat.pm`

- [ ] **Step 1: For each file, apply the four substitutions**

For each file in the list above:

1. Read the file.
2. Apply in order:
   - `App::Yath::Schema::Result::` → `App::Yath::Schema::DBIC::Result::` (global)
   - `App::Yath::Schema::ResultBase` → `App::Yath::Schema::DBIC::ResultBase` (global)
   - `App::Yath::Schema::ResultSet` → `App::Yath::Schema::DBIC::ResultSet` (global)
   - `App::Yath::Schema::(SQLite|PostgreSQL|MySQL|MariaDB|Percona)\b` → `App::Yath::Schema::DBIC::$1` (regex)
   - `\$App::Yath::Schema::LOADED` → `$App::Yath::Schema::DBIC::LOADED` (global)
   - Bare `use App::Yath::Schema;` → `use App::Yath::Schema::DBIC;`
   - Bare `'App::Yath::Schema'` or `"App::Yath::Schema"` (as a class name) → the DBIC version. **Do not** match `App::Yath::Schema::Util`, etc.
3. Syntax-check: `perl -Ilib -c <path>`.

- [ ] **Step 2: Syntax-check the group**

```
for f in lib/App/Yath/Schema/Util.pm \
         lib/App/Yath/Schema/Sync.pm \
         lib/App/Yath/Schema/Sweeper.pm \
         lib/App/Yath/Schema/RunProcessor.pm \
         lib/App/Yath/Schema/Importer.pm \
         lib/App/Yath/Schema/ImportModes.pm \
         lib/App/Yath/Schema/Queries.pm \
         lib/App/Yath/Schema/Config.pm \
         lib/App/Yath/Schema/DateTimeFormat.pm; do
  perl -Ilib -c $f || echo "FAIL: $f"
done
```

Expected: every file reports `syntax OK`.

- [ ] **Step 3: Commit**

```
git add lib/App/Yath/Schema/
git commit -m "refactor(schema): update schema-adjacent modules to DBIC namespace"
```

---

### Task 18: Rewrite the server / renderer / plugin layer

**Files to modify:**

- `lib/App/Yath/Server.pm`
- `lib/App/Yath/Server/Request.pm`
- `lib/App/Yath/Server/Controller/View.pm`
- `lib/App/Yath/Server/Controller/Upload.pm`
- `lib/App/Yath/Server/Controller/Sweeper.pm`
- `lib/App/Yath/Server/Controller/Stream.pm`
- `lib/App/Yath/Server/Controller/Resources.pm`
- `lib/App/Yath/Server/Controller/Query.pm`
- `lib/App/Yath/Server/Controller/Project.pm`
- `lib/App/Yath/Server/Controller/Lookup.pm`
- `lib/App/Yath/Server/Controller/Job.pm`
- `lib/App/Yath/Server/Controller/Interactions.pm`
- `lib/App/Yath/Renderer/Server.pm`
- `lib/App/Yath/Renderer/DB.pm`
- `lib/App/Yath/Plugin/DB.pm`
- `lib/App/Yath/Options/DB.pm`

- [ ] **Step 1: Apply the same substitution set as Task 17**

Apply the same 7 substitution rules from Task 17, Step 1, to each file in the list.

- [ ] **Step 2: Syntax-check the group**

```
for f in lib/App/Yath/Server.pm lib/App/Yath/Server/Request.pm \
         lib/App/Yath/Server/Controller/*.pm \
         lib/App/Yath/Renderer/Server.pm lib/App/Yath/Renderer/DB.pm \
         lib/App/Yath/Plugin/DB.pm lib/App/Yath/Options/DB.pm; do
  perl -Ilib -c $f || echo "FAIL: $f"
done
```

- [ ] **Step 3: Commit**

```
git add lib/App/Yath/
git commit -m "refactor(schema): update server/renderer/plugin to DBIC namespace"
```

---

### Task 19: Rewrite the command layer

**Files to modify:**

- `lib/App/Yath/Command/db.pm`
- `lib/App/Yath/Command/db/sync.pm`
- `lib/App/Yath/Command/db/sweeper.pm`
- `lib/App/Yath/Command/db/publish.pm`
- `lib/App/Yath/Command/db/importer.pm`
- `lib/App/Yath/Command/recent.pm`
- `lib/App/Yath/Command/server.pm`

- [ ] **Step 1: Apply substitutions**

Same 7 rules from Task 17, Step 1.

- [ ] **Step 2: Syntax-check**

```
for f in lib/App/Yath/Command/db.pm lib/App/Yath/Command/db/*.pm \
         lib/App/Yath/Command/recent.pm lib/App/Yath/Command/server.pm; do
  perl -Ilib -c $f || echo "FAIL: $f"
done
```

- [ ] **Step 3: Commit**

```
git add lib/App/Yath/Command/
git commit -m "refactor(schema): update command layer to DBIC namespace"
```

---

### Task 20: Update unit tests that reference Result classes

**Files to modify:**

- `t/unit/App/Yath/Schema/Result/*.t` (all ~29 files — backend-agnostic Result behavior tests)
- `t/unit/App/Yath/Schema.t`
- `t/unit/App/Yath/Schema/Config.t`
- `t/unit/App/Yath/Schema/Util.t`
- `t/unit/App/Yath/Schema/Sync.t`
- `t/unit/App/Yath/Schema/Sweeper.t`
- `t/unit/App/Yath/Schema/Queries.t`
- `t/unit/App/Yath/Schema/Importer.t`
- `t/unit/App/Yath/Schema/ImportModes.t`
- `t/unit/App/Yath/Schema/Loader.t`
- `t/unit/App/Yath/Schema/Dumper.t`
- `t/unit/App/Yath/Schema/DateTimeFormat.t`
- `t/unit/App/Yath/Schema/ResultBase.t`
- `t/unit/App/Yath/Schema/ResultSet.t`

- [ ] **Step 1: Apply substitutions**

Same 7 rules from Task 17, Step 1, to each file.

- [ ] **Step 2: Syntax-check**

```
for f in t/unit/App/Yath/Schema.t t/unit/App/Yath/Schema/*.t t/unit/App/Yath/Schema/Result/*.t; do
  perl -Ilib -Iauthor_tools/lib -c $f || echo "FAIL: $f"
done
```

- [ ] **Step 3: Commit**

```
git add t/unit/App/Yath/Schema/
git commit -m "refactor(tests): update unit tests to DBIC namespace"
```

---

### Task 21: Update ancillary tests and integration glue

**Files to modify:**

- `t/database/test.pl`
- `t/0-load_all.t`
- Existing per-backend coverage tests still referenced by ci:
  - `t/integration/coverage-sqlite.t`
  - `t/integration/coverage-pg.t`
  - `t/integration/coverage-mysql.t`
  - `t/integration/coverage-mariadb.t`
  - `t/integration/coverage-percona.t`

These integration tests will be replaced entirely in Task 25, but for now we just need them compiling so `0-load_all.t` passes.

- [ ] **Step 1: Apply substitutions**

Same 7 rules to each file.

- [ ] **Step 2: Syntax-check**

```
perl -Ilib -c t/database/test.pl
perl -Ilib -c t/0-load_all.t
for f in t/integration/coverage-*.t; do
  perl -Ilib -c $f || echo "FAIL: $f"
done
```

- [ ] **Step 3: Commit**

```
git add t/database/ t/0-load_all.t t/integration/coverage-*.t
git commit -m "refactor(tests): update ancillary tests to DBIC namespace"
```

---

### Task 22: Full syntax sweep and load test

- [ ] **Step 1: Syntax-check every .pm and .t file**

```
find lib t -type f \( -name '*.pm' -o -name '*.t' -o -name '*.pl' \) -print0 \
  | xargs -0 -n1 perl -Ilib -Iauthor_tools/lib -c 2>&1 \
  | grep -v 'syntax OK' \
  || echo 'all clean'
```

Expected output: `all clean`. Any file listed here failed to compile and must be fixed before moving on.

- [ ] **Step 2: Run `0-load_all.t` against SQLite**

```
YATH_SCHEMA_DRIVER=SQLite prove -Ilib t/0-load_all.t
```

Expected: pass, every module loads.

- [ ] **Step 3: Commit any fixes**

```
git add -A
git commit -m "fix(schema): resolve consumer-rewrite fallout"
```

---

## Phase 6 — Test infrastructure

### Task 23: Create `App::Yath::Test::DBIC::Database`

**Files:**
- Create: `t/lib/App/Yath/Test/DBIC/Database.pm`

- [ ] **Step 1: Write the module**

```perl
package App::Yath::Test::DBIC::Database;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw/ephemeral_server/;

use App::Yath::Schema::Config;
use App::Yath::Server;

# Spin up an ephemeral DB and return (config, server, dsn).
sub ephemeral_server {
    my (%args) = @_;
    my $driver = $args{driver} or die "driver required\n";

    my $config = App::Yath::Schema::Config->new(ephemeral => $driver);
    my $server = App::Yath::Server->new(schema_config => $config);
    my $db     = $server->start_ephemeral_db;
    my $dsn    = $db->connect_string('harness_ui');

    return ($config, $server, $dsn);
}

1;
```

- [ ] **Step 2: Syntax-check**

```
perl -It/lib -Ilib -c t/lib/App/Yath/Test/DBIC/Database.pm
```

- [ ] **Step 3: Commit**

```
git add t/lib/App/Yath/Test/DBIC/Database.pm
git commit -m "feat(tests): add App::Yath::Test::DBIC::Database helper"
```

---

### Task 24: Create `App::Yath::Test::DBIC::Schema`

**Files:**
- Create: `t/lib/App/Yath/Test/DBIC/Schema.pm`

- [ ] **Step 1: Write the module**

```perl
package App::Yath::Test::DBIC::Schema;
use strict;
use warnings;

use Test2::V0;

use Exporter 'import';
our @EXPORT_OK = qw/run_schema_tests/;

use App::Yath::Test::DBIC::Database qw/ephemeral_server/;

sub run_schema_tests {
    my (%args) = @_;
    my $driver = $args{driver} or die "driver required\n";

    my ($config, $server, $dsn) = ephemeral_server(driver => $driver);
    my $schema = $config->schema;

    subtest "load $driver schema" => sub {
        ok($schema, "schema connected for $driver");
    };

    subtest 'every Result class is loadable' => sub {
        my @sources = sort $schema->sources;
        ok(@sources >= 20, 'at least 20 sources registered') or diag "got @sources sources";
        for my $source_name (@sources) {
            my $rs = eval { $schema->resultset($source_name) };
            ok($rs, "resultset $source_name") or diag $@;
        }
    };

    subtest 'User password methods' => sub {
        my $users = $schema->resultset('User');
        my $u = $users->create({ username => 'test_user_' . $$, password => 'hunter2', role => 'user' });
        ok($u->verify_password('hunter2'), 'verify_password accepts correct');
        ok(!$u->verify_password('wrong'),  'verify_password rejects wrong');
        $u->delete;
    };

    # Add more subtests here as Phase 4's hand-verification surfaces
    # overlay methods worth regression-testing.
}

1;
```

- [ ] **Step 2: Syntax-check**

```
perl -It/lib -Ilib -c t/lib/App/Yath/Test/DBIC/Schema.pm
```

- [ ] **Step 3: Commit**

```
git add t/lib/App/Yath/Test/DBIC/Schema.pm
git commit -m "feat(tests): add App::Yath::Test::DBIC::Schema reusable tests"
```

---

### Task 25: Extract coverage test body into `App::Yath::Test::DBIC::Coverage`

**Files:**
- Read: `t/integration/coverage-sqlite.t` (the canonical source of the shared body)
- Create: `t/lib/App/Yath/Test/DBIC/Coverage.pm`

- [ ] **Step 1: Read the existing coverage test end-to-end**

```
wc -l t/integration/coverage-sqlite.t
```

It is ~355 lines. The body between the `my $db = $server->start_ephemeral_db;` line and `done_testing;` is identical across all 5 per-backend files — that body moves into the module.

- [ ] **Step 2: Write the module**

Create `t/lib/App/Yath/Test/DBIC/Coverage.pm` with:

```perl
package App::Yath::Test::DBIC::Coverage;
use strict;
use warnings;

use Test2::V0;
use Test2::Plugin::IsolateTemp;

use Exporter 'import';
our @EXPORT_OK = qw/run_coverage_tests/;

use App::Yath::Test::DBIC::Database qw/ephemeral_server/;
use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;
use Test2::Plugin::Immiscible(sub { $ENV{TEST2_HARNESS_ACTIVE} ? 1 : 0 });

sub run_coverage_tests {
    my (%args) = @_;
    my $driver = $args{driver} or die "driver required\n";

    # The integration tests derive $dir from __FILE__. Since we are now in a
    # shared module, take $dir from the caller so fixtures still resolve
    # relative to the invoking .t file.
    my $caller_file = (caller)[1];
    my $dir = $caller_file;
    $dir =~ s{\.t$}{};
    $dir =~ s{^\./}{};
    $dir =~ s/\d+$//;
    $dir =~ s{-(?:sqlite|postgresql|mysql|mariadb|percona)$}{};

    my ($config, $server, $dsn) = ephemeral_server(driver => $driver);

    my @yath_args = (
        '--db-dsn'       => $dsn,
        '--project'      => 'test',
        '--db-publisher' => 'root',
        '--publish-mode' => 'complete',
        '--renderer'     => 'DB',
        '--publish-user' => 'root',
    );

    # <<< paste the body of t/integration/coverage-sqlite.t from its first
    # `for (1 .. 2)` loop through the last `yath(...)` call here, verbatim.
    # The body uses only $dir, $server, @yath_args, and the imports above. >>>
}

1;
```

**Note:** The large body paste cannot be inlined in this plan without doubling its length. Copy the code literally from `t/integration/coverage-sqlite.t` lines 40–352 into the module.

- [ ] **Step 3: Syntax-check**

```
perl -It/lib -Ilib -c t/lib/App/Yath/Test/DBIC/Coverage.pm
```

- [ ] **Step 4: Commit**

```
git add t/lib/App/Yath/Test/DBIC/Coverage.pm
git commit -m "feat(tests): extract coverage body into App::Yath::Test::DBIC::Coverage"
```

---

### Task 26: Create the 10 per-backend shim tests

**Files to create:**

- `t/integration/dbic-schema-sqlite.t`
- `t/integration/dbic-schema-postgresql.t`
- `t/integration/dbic-schema-mysql.t`
- `t/integration/dbic-schema-mariadb.t`
- `t/integration/dbic-schema-percona.t`
- `t/integration/dbic-coverage-sqlite.t`
- `t/integration/dbic-coverage-postgresql.t`
- `t/integration/dbic-coverage-mysql.t`
- `t/integration/dbic-coverage-mariadb.t`
- `t/integration/dbic-coverage-percona.t`

- [ ] **Step 1: Create the schema shims**

For each of the 5 drivers `SQLite`, `PostgreSQL`, `MySQL`, `MariaDB`, `Percona` — and the corresponding lower-case filename suffix `sqlite`, `postgresql`, `mysql`, `mariadb`, `percona` — create `t/integration/dbic-schema-<suffix>.t`:

```perl
use Test2::V0;
use Test2::Tools::QuickDB;

use lib 't/lib';
use App::Yath::Test::DBIC::Schema qw/run_schema_tests/;

skipall_unless_can_db(driver => 'PostgreSQL');   # ← adjust per file

run_schema_tests(driver => 'PostgreSQL');         # ← adjust per file

done_testing;
```

- [ ] **Step 2: Create the coverage shims**

For the same 5 drivers, create `t/integration/dbic-coverage-<suffix>.t`:

```perl
use Test2::V0;
use Test2::Tools::QuickDB;

use lib 't/lib';
use App::Yath::Test::DBIC::Coverage qw/run_coverage_tests/;

skipall_unless_can_db(driver => 'PostgreSQL');   # ← adjust per file

run_coverage_tests(driver => 'PostgreSQL');       # ← adjust per file

done_testing;
```

- [ ] **Step 3: Syntax-check all 10**

```
for f in t/integration/dbic-*-*.t; do
  perl -It/lib -Ilib -c $f || echo "FAIL: $f"
done
```

- [ ] **Step 4: Commit**

```
git add t/integration/dbic-schema-*.t t/integration/dbic-coverage-*.t
git commit -m "feat(tests): add per-backend DBIC shim tests"
```

---

### Task 27: Delete replaced tests

**Files deleted:**

- `t/unit/App/Yath/Schema/SQLite/*.t` (and the directory)
- `t/unit/App/Yath/Schema/MariaDB/*.t` (and the directory)
- `t/UI/PostgreSQL.t`
- `t/UI/MySQL.t`
- `t/integration/coverage-sqlite.t`
- `t/integration/coverage-pg.t`
- `t/integration/coverage-mysql.t`
- `t/integration/coverage-mariadb.t`
- `t/integration/coverage-percona.t`

- [ ] **Step 1: Confirm replacements exist**

```
ls t/integration/dbic-*.t
ls t/lib/App/Yath/Test/DBIC/*.pm
```

Expected: 10 shim files and 3 shared modules.

- [ ] **Step 2: Delete the replaced trees**

```
git rm -r t/unit/App/Yath/Schema/SQLite t/unit/App/Yath/Schema/MariaDB
git rm    t/UI/PostgreSQL.t t/UI/MySQL.t
git rm    t/integration/coverage-sqlite.t \
          t/integration/coverage-pg.t \
          t/integration/coverage-mysql.t \
          t/integration/coverage-mariadb.t \
          t/integration/coverage-percona.t
```

- [ ] **Step 3: Commit**

```
git commit -m "refactor(tests): remove per-db unit tests and legacy coverage tests"
```

---

## Phase 7 — Validation

### Task 28: Run the new test suite against each backend

- [ ] **Step 1: Run against SQLite (always available)**

```
prove -It/lib -Ilib t/integration/dbic-schema-sqlite.t t/integration/dbic-coverage-sqlite.t
```

Expected: both pass.

- [ ] **Step 2: Run against every other available backend**

```
prove -It/lib -Ilib \
  t/integration/dbic-schema-postgresql.t t/integration/dbic-coverage-postgresql.t \
  t/integration/dbic-schema-mysql.t      t/integration/dbic-coverage-mysql.t      \
  t/integration/dbic-schema-mariadb.t    t/integration/dbic-coverage-mariadb.t    \
  t/integration/dbic-schema-percona.t    t/integration/dbic-coverage-percona.t
```

Expected: any backend whose QuickDB driver cannot start produces a `SKIP` rather than a failure. All available backends pass.

- [ ] **Step 3: Run the full unit test suite**

```
prove -It/lib -Ilib -r t/unit
```

Expected: all pass.

- [ ] **Step 4: Run the full integration suite**

```
prove -It/lib -Ilib -r t/integration
```

Expected: all pass.

- [ ] **Step 5: If anything fails, fix and commit**

```
git add -A
git commit -m "fix(schema): <description>"
```

Iterate until the suite is green.

---

### Task 29: Idempotency check — regen a second time

- [ ] **Step 1: Run regen without `--migrate`**

```
perl -Iauthor_tools/lib -Ilib author_tools/regen_schema.pl
```

Expected output: summary `fresh: 0, updated: 29, preserved tail: 29, migrated tail: 0`.

- [ ] **Step 2: Confirm the working tree is clean**

```
git diff --stat
```

Expected: empty. The generator is stable — a second run produced no diff.

- [ ] **Step 3: If diff is non-empty, investigate**

Any difference means either the generator is not fully idempotent (fix the emitter) or the splicer is not preserving the tail correctly (fix the splicer). Fix and re-run until step 2 shows no diff.

- [ ] **Step 4: Commit any fix**

```
git add -A
git commit -m "fix(regen): ensure idempotent output"
```

---

### Task 30: Final sweep and summary commit

- [ ] **Step 1: Run the full test suite one last time**

```
prove -It/lib -Ilib -r t
```

Expected: all pass (or skip cleanly when a DB driver is unavailable).

- [ ] **Step 2: Confirm no stale references**

```
grep -rE 'App::Yath::Schema::(Result|Overlay|SQLite|PostgreSQL|MySQL|MariaDB|Percona)(::|[^:])' lib t author_tools 2>&1 \
  | grep -v 'App::Yath::Schema::DBIC::' \
  | grep -v 'App::Yath::Schema/DBIC/' \
  || echo 'clean'
```

Expected: `clean`. Any remaining matches are un-updated consumer references and must be fixed.

- [ ] **Step 3: Confirm `regen_schema.pl` still passes its author tests**

```
prove -Iauthor_tools/lib author_tools/t
```

Expected: all pass (parser, merger, emitter, splicer, writer, overlay_migrator).

- [ ] **Step 4: Tag the completed refactor**

```
git tag post-dbic-migration
```

This gives a matched pair of tags (`pre-dbic-migration` / `post-dbic-migration`) for future reference.

---

## Self-Review

- **Spec coverage:** All 9 spec sections have corresponding tasks. Section 1 (namespace/layout) → Tasks 3, 4, 14, 16. Section 2 (unified module anatomy) → Tasks 14, 15. Section 3 (regen rewrite) → Tasks 5–12. Section 4 (consumer updates) → Tasks 17–22. Section 5 (test infrastructure) → Tasks 23–27. Section 6 (execution order) → the task ordering itself. Section 7 (risks) → each mitigation appears in a specific task (hand-verify in 15, idempotency in 29, marker die-loudly in 9).
- **Placeholder scan:** One intentional `...` in Task 12 step 2 for the `_emit_connection_modules` helper — flagged as "port the existing template", not a TBD. One `<<< paste body >>>` marker in Task 25 step 2 — flagged as "copy from coverage-sqlite.t lines 40–352". Both are delegated copies rather than undefined work. No other placeholders.
- **Type consistency:** `parse_dump`, `merge_backends`, `emit_result_body`, `splice_generated`, `build_new_result`, `extract_custom_tail`, `ephemeral_server`, `run_schema_tests`, `run_coverage_tests` — names used consistently across tasks. The parsed/merged spec shape is defined once in Task 6 and reused in Tasks 7–10. `Yath::Regen::DBIC::Branch` introduced in Task 7 and referenced in Task 8. All consistent.
- **Known gap:** the `_emit_connection_modules` helper in Task 12 relies on the engineer reading lines 135–199 of the old `regen_schema.pl` and porting the template. This is intentional to avoid duplicating 60 lines of boilerplate in the plan; the existing code is the source of truth. The lines 135–199 range was confirmed from earlier exploration.
