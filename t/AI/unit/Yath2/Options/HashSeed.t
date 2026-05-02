use Test2::V0;
use POSIX qw/strftime/;

# --set-hash-seed is an Auto-type option living under Tests:
#   * absent          -> the slot stays undef so the harness leaves
#                        PERL_HASH_SEED untouched on test children.
#   * --set-hash-seed -> autofill returns today as YYYYMMDD
#                        (matches the App-Yath-Script wrapper).
#   * --set-hash-seed=12345 -> verbatim value.

package TestHashSeed {
    use Getopt::Yath;
    include_options('App::Yath2::Options::Tests');
}

sub parse {
    my @argv = @_;
    local %ENV = %ENV;
    delete $ENV{PERL_HASH_SEED};
    my $state = TestHashSeed::parse_options([@argv]);
    return $state->{settings}->tests;
}

subtest 'absent: slot is undef' => sub {
    my $tests = parse();
    is($tests->set_hash_seed, undef, '--set-hash-seed not provided => undef');
};

subtest '--set-hash-seed (no value): autofills today as YYYYMMDD' => sub {
    my $tests = parse('--set-hash-seed');
    my $seed  = $tests->set_hash_seed;
    ok(defined $seed,         'seed defined');
    like($seed, qr/^\d{8}$/,  'seed matches /\\d{8}/');
    is($seed, strftime('%Y%m%d', localtime), 'seed equals today YYYYMMDD');
};

subtest '--set-hash-seed=12345: verbatim' => sub {
    my $tests = parse('--set-hash-seed=12345');
    is($tests->set_hash_seed, '12345', 'verbatim value preserved');
};

subtest '--set-hash-seed=non-numeric: also verbatim' => sub {
    # Auto type does not constrain the value; the user owns it.
    my $tests = parse('--set-hash-seed=DEADBEEF');
    is($tests->set_hash_seed, 'DEADBEEF', 'string value preserved');
};

subtest 'today_yyyymmdd helper' => sub {
    require App::Yath2::Options::Tests;
    my $today = App::Yath2::Options::Tests::today_yyyymmdd();
    like($today, qr/^\d{8}$/,                  'helper returns 8 digits');
    is($today, strftime('%Y%m%d', localtime),  'helper matches strftime');
};

done_testing;
