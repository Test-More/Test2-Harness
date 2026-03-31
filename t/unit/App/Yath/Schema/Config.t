use Test2::V0 -target => 'App::Yath::Schema::Config';

require App::Yath::Schema::Config;

can_ok(
    'App::Yath::Schema::Config',
    [qw/ dbi_dsn dbi_user dbi_pass schema connect disconnect
         push_ephemeral_credentials pop_ephemeral_credentials
         db_driver guess_db_driver TO_JSON /],
    'has all expected methods'
);

subtest 'push and pop ephemeral credentials' => sub {
    my $config = App::Yath::Schema::Config->new(
        dbi_dsn  => 'dbi:SQLite::memory:',
        dbi_user => 'origuser',
        dbi_pass => 'origpass',
    );

    is($config->dbi_user, 'origuser', "initial user");

    $config->push_ephemeral_credentials(
        dbi_dsn  => 'dbi:SQLite::memory:',
        dbi_user => 'tmpuser',
        dbi_pass => 'tmppass',
    );
    is($config->dbi_user, 'tmpuser', "ephemeral user pushed");
    is($config->dbi_pass, 'tmppass', "ephemeral pass pushed");

    $config->pop_ephemeral_credentials;
    is($config->dbi_user, 'origuser', "original user restored after pop");
    is($config->dbi_pass, 'origpass', "original pass restored after pop");
};

subtest 'TO_JSON omits schema object' => sub {
    my $config = App::Yath::Schema::Config->new(
        dbi_dsn  => 'dbi:SQLite::memory:',
        dbi_user => 'user',
        dbi_pass => 'pass',
    );

    my $json = $config->TO_JSON;
    ref_ok($json, 'HASH', 'TO_JSON returns a hashref');
    ok(!exists $json->{_schema}, '_schema is excluded from TO_JSON');
};

done_testing;
