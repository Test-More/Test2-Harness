use Test2::V0 -target => 'Test2::Harness::UI::Schema::Result::User';

use lib 't/lib';
use Test2::Harness::DB::Postgresql;

my $db = Test2::Harness::DB::Postgresql->new();

my $schema = $db->schema;

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

my $feed1 = $schema->resultset('Feed')->create({user_ui_id => $user->user_ui_id, api_key_ui_id => 1});
my $feed2 = $schema->resultset('Feed')->create({user_ui_id => $user->user_ui_id, api_key_ui_id => 1});

is([sort map { $_->feed_ui_id } $user->feeds->all], [sort $feed1->feed_ui_id, $feed2->feed_ui_id], "Found feeds");

done_testing;
