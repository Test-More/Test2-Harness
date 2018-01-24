use Test2::V0 -target => 'Test2::Harness::UI::Schema::Result::User';
# HARNESS-NO-TIMEOUT

use lib 't/lib';
use Test2::Harness::DB::Postgresql;

my $db = Test2::Harness::DB::Postgresql->new();

$db->import_simple_data();

my $schema = $db->connect;

my $user = $schema->resultset('User')->create({
    username => 'theuser',
    password => 'thepass',
});

ok($user->verify_password('thepass'), "Password verified");
ok(!$user->verify_password('thepas'), "Password not verified");

$schema->txn_do(sub {
    $user->set_password('foo');
    $user->update;
});

ok(!$user->verify_password('thepass'), "Password not verified");
ok($user->verify_password('foo'), "Password verified");

my $hash = $user->pw_hash;
my $salt = $user->pw_salt;

my $addr = "$user";
$user = undef;

$schema->resultset('User')->clear_cache;

$user = $schema->resultset('User')->find_or_create({username => 'theuser'});

ok("$user" ne $addr, "Got a new instance");
is($user->pw_hash, $hash, "hash was stored properly");
is($user->pw_salt, $salt, "salt was stored properly");

ok($user->gen_salt ne $user->gen_salt, "Different salt each time it is generated");

my $stream1 = $schema->resultset('Stream')->create({user_id => $user->user_id});
my $stream2 = $schema->resultset('Stream')->create({user_id => $user->user_id});

is([sort map { $_->stream_id } $user->streams->all], [$stream1->stream_id, $stream2->stream_id], "Found streams");

sleep 1000000;

done_testing;
