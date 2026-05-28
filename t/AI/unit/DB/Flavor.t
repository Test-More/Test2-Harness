use v5.38;
use Test2::V0;
use Test2::Harness2::DB::Flavor;

my $F = 'Test2::Harness2::DB::Flavor';

subtest by_name => sub {
    my $sqlite = $F->by_name('sqlite');
    is($sqlite->name,           'sqlite',     'name');
    is($sqlite->dialect,        'SQLite',     'dialect');
    is($sqlite->ddl_file,       'sqlite.sql', 'ddl_file');
    is($sqlite->quickdb_driver, 'SQLite',     'quickdb_driver');
    ok($sqlite->is_default, 'sqlite is default');

    is($F->by_name('postgresql')->dialect, 'PostgreSQL',     'pg dialect');
    is($F->by_name('mysql')->dialect,      'MySQL',          'mysql dialect');
    is($F->by_name('mariadb')->dialect,    'MySQL::MariaDB', 'mariadb dialect');
    is($F->by_name('percona')->dialect,    'MySQL::Percona', 'percona dialect');

    ok(!$F->by_name('mysql')->is_default, 'mysql not default');
    like(dies { $F->by_name('nope') }, qr/unknown flavor 'nope'/, 'croaks on unknown, lists known');
};

subtest infer_from_dsn => sub {
    is($F->infer_from_dsn('dbi:Pg:dbname=foo')->name,   'postgresql', 'Pg DSN');
    is($F->infer_from_dsn('dbi:SQLite:dbname=x')->name, 'sqlite',     'SQLite DSN');
    is($F->infer_from_dsn('dbi:mysql:database=foo'),    undef,        'mysql DSN ambiguous -> undef');
    is($F->infer_from_dsn('dbi:MariaDB:database=foo'),  undef,        'MariaDB DSN ambiguous -> undef');
    is($F->infer_from_dsn('dbi:Oracle:x'),              undef,        'unknown DSN -> undef');
};

subtest is_mysql_family => sub {
    ok($F->by_name('mysql')->is_mysql_family,       'mysql is family');
    ok($F->by_name('mariadb')->is_mysql_family,     'mariadb is family');
    ok($F->by_name('percona')->is_mysql_family,     'percona is family');
    ok(!$F->by_name('postgresql')->is_mysql_family, 'pg not family');
    ok(!$F->by_name('sqlite')->is_mysql_family,     'sqlite not family');
};

subtest detect_from_dbh => sub {
    my $stub = sub ($version, $comment) {
        my $obj = mock {} => (
            add => [
                selectrow_array => sub ($self, $sql, @) {
                    return $version if $sql =~ /VERSION\(\)/i;
                    return $comment if $sql =~ /version_comment/i;
                    return;
                },
            ],
        );
        return $obj;
    };

    is($F->detect_from_dbh($stub->('10.11.2-MariaDB', 'mariadb.org binary'))->name,     'mariadb', 'MariaDB version string');
    is($F->detect_from_dbh($stub->('8.0.35-27',       'Percona Server'))->name,         'percona', 'Percona version_comment');
    is($F->detect_from_dbh($stub->('8.0.35',          'MySQL Community Server'))->name, 'mysql',   'plain MySQL');
    is($F->detect_from_dbh($stub->('unknown-db 1.0',  'FooDB')),                        undef,     'unknown engine returns undef');
};

done_testing;
