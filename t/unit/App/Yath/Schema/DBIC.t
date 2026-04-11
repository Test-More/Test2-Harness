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

# Method-form wrappers must also work, since existing consumers call
# $schema->is_postgresql as a method.
{
    local $App::Yath::Schema::DBIC::LOADED = 'PostgreSQL';
    ok(App::Yath::Schema::DBIC->is_postgresql, 'method-form is_postgresql');
    ok(!App::Yath::Schema::DBIC->is_sqlite,    'method-form is_sqlite false');
    is(App::Yath::Schema::DBIC->format_uuid_for_db('x'), 'x', 'method-form format_uuid_for_db');
}

done_testing;
