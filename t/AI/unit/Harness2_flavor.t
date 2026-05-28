use Test2::V0;
use File::Temp qw/tempdir/;
use Test2::Harness2;

my $dir = tempdir(CLEANUP => 1);

subtest default_sqlite => sub {
    my $h = Test2::Harness2->new(db_path => "$dir/h.sqlite");
    is($h->flavor_obj->name, 'sqlite', 'db_path defaults to sqlite flavor');
    my $spec = $h->connect_spec;
    is($spec->{flavor},  'sqlite',        'spec flavor');
    is($spec->{db_path}, "$dir/h.sqlite", 'spec db_path');
    ok(!exists $spec->{dsn}, 'no dsn in sqlite spec');
};

subtest explicit_flavor_wins => sub {
    my $h = Test2::Harness2->new(
        flavor   => 'postgresql',
        dsn      => 'dbi:Pg:dbname=foo',
        username => 'u',
        password => 'p',
    );
    is($h->flavor_obj->name, 'postgresql', 'explicit flavor');
    my $spec = $h->connect_spec;
    is($spec->{flavor},   'postgresql',        'spec flavor');
    is($spec->{dsn},      'dbi:Pg:dbname=foo', 'spec dsn');
    is($spec->{username}, 'u', 'spec username');
    is($spec->{password}, 'p', 'spec password');
};

subtest infer_pg_from_dsn => sub {
    my $h = Test2::Harness2->new(dsn => 'dbi:Pg:dbname=foo');
    is($h->flavor_obj->name, 'postgresql', 'pg inferred from dsn');
};

subtest mysql_family_unresolved_defers => sub {
    my $h = Test2::Harness2->new(dsn => 'dbi:mysql:database=foo');
    is($h->flavor_obj, undef, 'mysql-family flavor deferred to connect-time probe');
};

done_testing;
