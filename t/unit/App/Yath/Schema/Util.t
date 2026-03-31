use Test2::V0 -target => 'App::Yath::Schema::Util';

use App::Yath::Schema::Util qw/
    format_duration parse_duration
    is_invalid_subtest_name
    qdb_driver dbd_driver format_driver
/;

subtest format_duration => sub {
    like(format_duration(0),     qr/^\d+\.\d+s$/, "zero seconds matches duration pattern");
    like(format_duration(1),     qr/^\d+\.\d+s$/, "one second matches duration pattern");
    like(format_duration(59),    qr/^\d+\.\d+s$/, "59 seconds matches duration pattern");
    like(format_duration(60),    qr/^\d+m:\d+\.\d+s$/, "60 seconds shows minutes");
    like(format_duration(3600),  qr/^\d+h:\d+m:\d+\.\d+s$/, "3600 seconds shows hours");
    like(format_duration(86400), qr/^\d+d:\d+h:\d+m:\d+\.\d+s$/, "86400 seconds shows days");

    for my $secs (0, 1, 30, 59, 60, 61, 90, 3600, 3661, 3723, 86400, 86461, 90061) {
        is(parse_duration(format_duration($secs)), $secs, "round-trip for $secs seconds");
    }
};

subtest parse_duration => sub {
    is(parse_duration(0),  0, "zero returns 0");
    is(parse_duration(""), 0, "empty string returns 0");

    is(parse_duration(42),   42,  "plain integer passes through");
    is(parse_duration(3.14), 3.14, "plain float passes through");

    is(parse_duration("30s"),   30,    "seconds only");
    is(parse_duration("2m"),    120,   "minutes only");
    is(parse_duration("1h"),    3600,  "hours only");
    is(parse_duration("1d"),    86400, "days only");

    is(parse_duration("1m:30s"),         90,    "minutes and seconds");
    is(parse_duration("1h:0m:0s"),       3600,  "hours with zero remainder");
    is(parse_duration("1h:1m:1s"),       3661,  "hours minutes seconds");
    is(parse_duration("1d:2h:3m:4s"),    93784, "days hours minutes seconds");
};

subtest is_invalid_subtest_name => sub {
    ok(is_invalid_subtest_name('__ANON__'),            "__ANON__ is invalid");
    ok(is_invalid_subtest_name('unnamed'),             "unnamed is invalid");
    ok(is_invalid_subtest_name('unnamed subtest'),     "unnamed subtest is invalid");
    ok(is_invalid_subtest_name('unnamed summary'),     "unnamed summary is invalid");
    ok(is_invalid_subtest_name('<UNNAMED ASSERTION>'), "UNNAMED ASSERTION is invalid");

    ok(!is_invalid_subtest_name('my test'), "regular name is valid");
    ok(!is_invalid_subtest_name('foo'),     "short name is valid");
    ok(!is_invalid_subtest_name(''),        "empty string is not in the bad list");
};

subtest qdb_driver => sub {
    is(qdb_driver('sqlite'),     'SQLite',     "sqlite");
    is(qdb_driver('mysql'),      'MySQL',      "mysql");
    is(qdb_driver('postgresql'), 'PostgreSQL', "postgresql");
    is(qdb_driver('pg'),         'PostgreSQL', "pg alias");
    is(qdb_driver('mariadb'),    'MariaDB',    "mariadb");
    is(qdb_driver('percona'),    'Percona',    "percona");
};

subtest dbd_driver => sub {
    is(dbd_driver('sqlite'),     'DBD::SQLite', "sqlite");
    is(dbd_driver('mysql'),      'DBD::mysql',  "mysql");
    is(dbd_driver('postgresql'), 'DBD::Pg',     "postgresql");
    is(dbd_driver('pg'),         'DBD::Pg',     "pg alias");
    is(dbd_driver('mariadb'),    'DBD::mysql',  "mariadb");
    is(dbd_driver('percona'),    'DBD::mysql',  "percona");
};

subtest format_driver => sub {
    is(format_driver('sqlite'),     'DateTime::Format::SQLite', "sqlite");
    is(format_driver('mysql'),      'DateTime::Format::MySQL',  "mysql");
    is(format_driver('postgresql'), 'DateTime::Format::Pg',     "postgresql");
    is(format_driver('pg'),         'DateTime::Format::Pg',     "pg alias");
    is(format_driver('mariadb'),    'DateTime::Format::MySQL',  "mariadb");
    is(format_driver('percona'),    'DateTime::Format::MySQL',  "percona");
};

done_testing;
