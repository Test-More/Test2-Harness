use Test2::V0;
use Test2::IPC;
use Test2::Tools::QuickDB;

use Storable qw/dclone/;

BEGIN { $ENV{T2_HARNESS_UI_ENV} = 'dev' };
use Test2::Harness::UI::UUID qw/ uuid_inflate uuid_deflate gen_uuid uuid_mass_inflate uuid_mass_deflate looks_like_uuid_36_or_16 /;
use Test2::Harness::UI::Util qw/dbd_driver qdb_driver share_file/;
use Test2::Util qw/pkg_to_file/;

imported_ok qw/ uuid_inflate uuid_deflate gen_uuid uuid_mass_inflate uuid_mass_deflate looks_like_uuid_36_or_16 /;

ok(my $uuid = gen_uuid, "Got a uuid");
isa_ok($uuid, ['Test2::Harness::UI::UUID'], "Constructed as an object");
is("$uuid", $uuid->{string}, "Stringified the uuid");

is(uuid_inflate($uuid->{binary})->string, $uuid->{string}, "Round trip string -> binary -> string");
is(uuid_inflate($uuid->{string})->binary, $uuid->{binary}, "Round trip binary -> string -> binary");

subtest undef => sub {
    is(uuid_inflate('x'),   undef, "Invalid uuid");
    is(uuid_inflate('1'),   undef, "Invalid uuid");
    is(uuid_inflate(0),     undef, "Invalid uuid");
    is(uuid_inflate(''),    undef, "Invalid uuid");
    is(uuid_inflate(undef), undef, "Invalid uuid");

    is(uuid_deflate('x'),   undef, "Invalid uuid");
    is(uuid_deflate('1'),   undef, "Invalid uuid");
    is(uuid_deflate(0),     undef, "Invalid uuid");
    is(uuid_deflate(''),    undef, "Invalid uuid");
    is(uuid_deflate(undef), undef, "Invalid uuid");
};

sub as_hex {
    my ($val) = @_;
    return uc(join "" => map {sprintf("%02X", ord($_))} split //, $val);
}

my @pids;
for my $schema_name (qw/MySQL MySQL56 PostgreSQL/) {
    my $pid = fork;
    if ($pid) {
        push @pids => $pid;
        next;
    }

    subtest "$schema_name Search and Find" => sub {
        my $driver = qdb_driver($schema_name);
        skipall_unless_can_db(driver => $driver);
        require DBIx::QuickDB;
        require Test2::Harness::UI::Config;

        require(pkg_to_file("Test2::Harness::UI::Schema::${schema_name}"));

        my $db  = DBIx::QuickDB->build_db("harness_ui" => {driver => qdb_driver($schema_name), dbd_driver => dbd_driver($schema_name)});
        my $dbh = $db->connect('quickdb', AutoCommit => 1, RaiseError => 1);

        $dbh->do('CREATE DATABASE harness_ui') or die "Could not create db " . $dbh->errstr;
        $db->load_sql(harness_ui => share_file("schema/${schema_name}.sql"));

        my $dsn = $db->connect_string('harness_ui');

        $ENV{HARNESS_UI_DSN} = $dsn;
        my $config = Test2::Harness::UI::Config->new(
            dbi_dsn     => $dsn,
            dbi_user    => '',
            dbi_pass    => '',
            single_user => 1,
            show_user   => 1,
            email       => 'exodist7@gmail.com',
        );

        my $schema  = $config->schema;
        my $user_rs = $schema->resultset('User');

        my $user_id = gen_uuid();
        my $user    = $user_rs->create({username => 'root', password => 'root', realname => 'root', user_id => $user_id});
        ok($user, "Created user");

        my $u1 = $user_rs->search({user_id => $user_id})->first;
        is($u1->user_id, $user_id->string, "Found user using search");

        my $u2 = $user_rs->find({user_id => $user_id});
        is($u2->user_id, $user_id->string, "Found user using find");

        my $u3 = $user_rs->find_or_create({user_id => $user_id, username => 'root'});
        is($u3->user_id, $user_id->string, "Found user using find_or_create");

        my $user_id2 = gen_uuid();
        my $u4       = $user_rs->find_or_create({user_id => $user_id2, username => 'foo'});
        is($u4->user_id, $user_id2->string, "Created using find_or_create");

        return unless $schema_name =~ m/mysql/i;

        my $sth = $dbh->prepare('SELECT @@version');
        $sth->execute();
        my $out = $sth->fetchall_arrayref;

        return unless $out->[0]->[0] =~ m/^(\d+)/;
        return unless int($1) >= 8;

        $sth = $dbh->prepare("SELECT uuid_to_bin(?, true) AS bin");
        $sth->execute($user_id->{string});
        $out = $sth->fetchall_arrayref;
        is($out->[0]->[0], $user_id->{binary}, "We use the same format as uuid_to_bin(..., true) (binary form)");
        is(as_hex($out->[0]->[0]), as_hex($user_id->{binary}), "We use the same format as uuid_to_bin(..., true) (human form)");
    };

    exit 0;
}

waitpid($_, 0) for @pids;

subtest mysql => sub {
    local $Test2::Harness::UI::Schema::LOADED = 'MySQL';

    my $bin = uuid_deflate($uuid);
    ok($bin !~ m/^[[:ascii:]]+$/s, "Looks Binary");
    is(length($bin), 16, "16 bytes long");

    ok(looks_like_uuid_36_or_16($bin),                "Looks like a 16 byte uuid");
    ok(looks_like_uuid_36_or_16("$uuid"),             "Looks like a 36 byte uuid");
    ok(!looks_like_uuid_36_or_16("abdghtyaslkguicd"), "16 length, but not a uuid");

    is(uuid_inflate($bin), $uuid, "Inflated from binary");

    is(uuid_inflate(uuid_deflate($uuid)), $uuid, "Round trip 1");
    is(uuid_deflate(uuid_inflate($bin)),  $bin,  "Round trip 1");

    my $uuid1 = gen_uuid;
    my $uuid2 = gen_uuid;

    my $raw = {
        foo_id  => $uuid1->string,
        foo_key => $uuid1->string,
        owner   => $uuid1->string,
        foo     => $uuid1->string,    # Should not convert

        bar => "asdfghjkaloertyuiaslxuertm6uaoq23vbg",
        bat => ['a' x 16],
        ban => ['a' x 36],

        boo => [
            [$uuid],
            {foo_id => $uuid},
        ],

        baz => {
            a     => $uuid->string,    # Should not convert
            a_id  => $uuid->string,
            a_key => $uuid->string,
            owner => $uuid->string,

            b => [$uuid->string, $uuid1->string, $uuid2->string],
            c => [$uuid->binary, $uuid1->binary, $uuid1->binary],
            d => [$uuid,         $uuid1,         $uuid2],

            e => {
                a_id  => $uuid,
                b_key => $uuid->binary,
                owner => $uuid1->binary
            },
        },
    };

    my $deflated = {
        foo_id  => $uuid1->binary,
        foo_key => $uuid1->binary,
        owner   => $uuid1->binary,
        foo     => $uuid1->string,    # Should not convert

        bar => "asdfghjkaloertyuiaslxuertm6uaoq23vbg",
        bat => ['a' x 16],
        ban => ['a' x 36],

        boo => [
            [$uuid->binary],
            {foo_id => $uuid->binary},
        ],

        baz => {
            a     => $uuid->string,    # Should not convert
            a_id  => $uuid->binary,
            a_key => $uuid->binary,
            owner => $uuid->binary,

            b => [$uuid->binary, $uuid1->binary, $uuid2->binary],
            c => [$uuid->binary, $uuid1->binary, $uuid1->binary],
            d => [$uuid->binary, $uuid1->binary, $uuid2->binary],

            e => {
                a_id  => $uuid->binary,
                b_key => $uuid->binary,
                owner => $uuid1->binary,
            },
        },
    };

    my $inflated = {
        foo_id  => $uuid1,
        foo_key => $uuid1,
        owner   => $uuid1,
        foo     => $uuid1->string,    # Should not convert

        bar => "asdfghjkaloertyuiaslxuertm6uaoq23vbg",
        bat => ['a' x 16],
        ban => ['a' x 36],

        boo => [
            [$uuid],
            {foo_id => $uuid},
        ],

        baz => {
            a     => $uuid->string,    # Should not convert
            a_id  => $uuid,
            a_key => $uuid,
            owner => $uuid,

            b => [$uuid, $uuid1, $uuid2],
            c => [$uuid, $uuid1, $uuid1],
            d => [$uuid, $uuid1, $uuid2],

            e => {
                a_id  => $uuid,
                b_key => $uuid,
                owner => $uuid1,
            },
        },
    };

    is(uuid_mass_inflate(dclone($raw)), $inflated, "Inflate went well");
    is(uuid_mass_deflate(dclone($raw)), $deflated, "Deflate went well");

    is(uuid_mass_inflate(dclone($inflated)), $inflated, "Inflate to Inflate went well");
    is(uuid_mass_deflate(dclone($deflated)), $deflated, "Deflate to Deflate went well");

    is(uuid_mass_inflate(dclone($deflated)), $inflated, "Deflate to Inflate went well");
    is(uuid_mass_deflate(dclone($inflated)), $deflated, "Inflate to Deflate went well");
};

subtest not_mysql => sub {
    local $Test2::Harness::UI::Schema::LOADED = 'Other';

    is(uuid_deflate($uuid), $uuid->{string}, "Deflate to string");

    ok(looks_like_uuid_36_or_16("$uuid"),             "Looks like a 36 byte uuid");
    ok(!looks_like_uuid_36_or_16("abdghtyaslkguicd"), "16 length, but not a uuid");

    is(uuid_inflate(uuid_deflate($uuid)), $uuid, "Round trip 1");

    my $uuid1 = gen_uuid;
    my $uuid2 = gen_uuid;

    my $raw = {
        foo_id  => $uuid1->string,
        foo_key => $uuid1->string,
        owner   => $uuid1->string,
        foo     => $uuid1->string,    # Should not convert

        bar => "asdfghjkaloertyuiaslxuertm6uaoq23vbg",
        bat => ['a' x 16],
        ban => ['a' x 36],

        boo => [
            [$uuid],
            {foo_id => $uuid},
        ],

        baz => {
            a     => $uuid->string,    # Should not convert
            a_id  => $uuid->string,
            a_key => $uuid->string,
            owner => $uuid->string,

            b => [$uuid->string, $uuid1->string, $uuid2->string],
            c => [$uuid->binary, $uuid1->binary, $uuid1->binary],
            d => [$uuid,         $uuid1,         $uuid2],

            e => {
                a_id  => $uuid,
                b_key => $uuid->binary,
                owner => $uuid1->binary
            },
        },
    };

    my $deflated = {
        foo_id  => $uuid1->string,
        foo_key => $uuid1->string,
        owner   => $uuid1->string,
        foo     => $uuid1->string,    # Should not convert

        bar => "asdfghjkaloertyuiaslxuertm6uaoq23vbg",
        bat => ['a' x 16],
        ban => ['a' x 36],

        boo => [
            [$uuid->string],
            {foo_id => $uuid->string},
        ],

        baz => {
            a     => $uuid->string,    # Should not convert
            a_id  => $uuid->string,
            a_key => $uuid->string,
            owner => $uuid->string,

            b => [$uuid->string, $uuid1->string, $uuid2->string],
            c => [$uuid->string, $uuid1->string, $uuid1->string],
            d => [$uuid->string, $uuid1->string, $uuid2->string],

            e => {
                a_id  => $uuid->string,
                b_key => $uuid->string,
                owner => $uuid1->string,
            },
        },
    };

    my $inflated = {
        foo_id  => $uuid1,
        foo_key => $uuid1,
        owner   => $uuid1,
        foo     => $uuid1->string,    # Should not convert

        bar => "asdfghjkaloertyuiaslxuertm6uaoq23vbg",
        bat => ['a' x 16],
        ban => ['a' x 36],

        boo => [
            [$uuid],
            {foo_id => $uuid},
        ],

        baz => {
            a     => $uuid->string,    # Should not convert
            a_id  => $uuid,
            a_key => $uuid,
            owner => $uuid,

            b => [$uuid, $uuid1, $uuid2],
            c => [$uuid, $uuid1, $uuid1],
            d => [$uuid, $uuid1, $uuid2],

            e => {
                a_id  => $uuid,
                b_key => $uuid,
                owner => $uuid1,
            },
        },
    };

    is(uuid_mass_inflate(dclone($raw)), $inflated, "Inflate went well");
    is(uuid_mass_deflate(dclone($raw)), $deflated, "Deflate went well");

    is(uuid_mass_inflate(dclone($inflated)), $inflated, "Inflate to Inflate went well");
    is(uuid_mass_deflate(dclone($deflated)), $deflated, "Deflate to Deflate went well");

    is(uuid_mass_inflate(dclone($deflated)), $inflated, "Deflate to Inflate went well");
    is(uuid_mass_deflate(dclone($inflated)), $deflated, "Inflate to Deflate went well");
};

done_testing;
