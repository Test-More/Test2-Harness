use Test2::V0; # -target => 'App::Yath::Schema::Result::User'

eval { require App::Yath::Schema::SQLite; 1 }
    or plan skip_all => "SQLite schema not available: $@";

eval { require Crypt::Eksblowfish::Bcrypt; 1 }
    or plan skip_all => "Crypt::Eksblowfish::Bcrypt not available: $@";

{
    package Test::MockUser;
    our @ISA = ('App::Yath::Schema::Result::User');
    sub new    { bless {%{$_[1]}}, $_[0] }
    sub update {
        my ($self, $data) = @_;
        $self->{$_} = $data->{$_} for keys %$data;
    }
    sub pw_hash { $_[0]->{pw_hash} }
    sub pw_salt { $_[0]->{pw_salt} }
}

isa_ok('App::Yath::Schema::Result::User', ['App::Yath::Schema::ResultBase'], 'inherits from ResultBase');
can_ok('App::Yath::Schema::Result::User', [qw/verify_password set_password gen_salt gen_api_key/], 'has overlay methods');

subtest 'gen_salt' => sub {
    my $salt = App::Yath::Schema::Result::User->gen_salt;
    is(length($salt), 16, "salt is 16 bytes");

    my $salt2 = App::Yath::Schema::Result::User->gen_salt;
    isnt($salt, $salt2, "two salts are different (probabilistic)");
};

use constant COST => 8;

subtest 'verify_password' => sub {
    Crypt::Eksblowfish::Bcrypt->import(qw/bcrypt_hash en_base64/);

    my $password = 'secret123';
    my $salt     = App::Yath::Schema::Result::User->gen_salt;
    my $hash     = bcrypt_hash({key_nul => 1, cost => COST, salt => $salt}, $password);

    my $user = Test::MockUser->new({
        pw_hash => en_base64($hash),
        pw_salt => en_base64($salt),
    });

    ok($user->verify_password($password),      "correct password verifies");
    ok(!$user->verify_password('wrong'),        "wrong password fails");
    ok(!$user->verify_password(''),             "empty password fails");
};

subtest 'set_password' => sub {
    my $user = Test::MockUser->new({pw_hash => 'old', pw_salt => 'old'});
    $user->set_password('newpassword');

    isnt($user->pw_hash, 'old', "pw_hash updated");
    isnt($user->pw_salt, 'old', "pw_salt updated");
    ok($user->verify_password('newpassword'), "new password verifies after set_password");
};

done_testing;
