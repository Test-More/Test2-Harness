use Test2::V0;
use Cwd qw/getcwd abs_path/;
use File::Temp ();

# Ensure @INC entries survive a chdir: the loader for
# algorithm()'s "fair"/"first" paths runs a dynamic require, and
# relative @INC entries (like "lib") would not resolve after we
# chdir into the fixture directory.
BEGIN {
    @INC = map { ref($_) ? $_ : abs_path($_) // $_ } @INC;
}

use App::Yath2::Resource::SharedJobSlots::Config;
use App::Yath2::Resource::SharedJobSlots::State;    # so algorithm() can reflect

my $CLASS = 'App::Yath2::Resource::SharedJobSlots::Config';

# The config loader walks upward looking for .sharedjobslots.yml, so
# chdir into the fixture directory before each find() call. The test
# file and its sibling .sharedjobslots.yml live together.
my $fixture_dir = __FILE__;
$fixture_dir =~ s{Config\.t$}{}g;
$fixture_dir = abs_path($fixture_dir) // $fixture_dir;

my $start_cwd = getcwd();
chdir($fixture_dir) or die "chdir($fixture_dir) failed: $!";

subtest 'host-specific section trumps COMMON' => sub {
    my $one = $CLASS->find(host => 'foo');
    ok($one, "located config");

    is($one->host,                'foo',                         "host");
    is($one->config_file,         '.sharedjobslots.yml',         "config_file");
    is($one->state_umask,         0007,                          "state_umask default");
    is($one->state_file,          '/tmp/yath2-state-config-test', "state_file from COMMON");
    is($one->algorithm,           '_redistribute_fair',          "algorithm from COMMON");
    is($one->max_slots,           13,                            "max_slots from host");
    is($one->min_slots_per_run,   0,                             "min_slots_per_run default");
    is($one->max_slots_per_job,   5,                             "max_slots_per_job from host");
    is($one->max_slots_per_run,   13,                            "max_slots_per_run from host");
    is($one->default_slots_per_job, 2,                           "default_slots_per_job from host");
    is($one->default_slots_per_run, 3,                           "default_slots_per_run from host");
};

subtest 'host umask override' => sub {
    my $one = $CLASS->find(host => 'bar');
    is($one->state_umask, '0077', "host state_umask");
};

subtest 'bat empty host section falls through to COMMON' => sub {
    my $one = $CLASS->find(host => 'bat');
    is($one->algorithm,             '_redistribute_fair', "algorithm from COMMON");
    is($one->max_slots,             4,                    "max_slots from COMMON");
    is($one->max_slots_per_job,     2,                    "max_slots_per_job from COMMON");
    is($one->max_slots_per_run,     4,                    "max_slots_per_run from COMMON");
    is($one->default_slots_per_job, 2,                    "default_slots_per_job from COMMON");
    is($one->default_slots_per_run, 2,                    "default_slots_per_run from COMMON");
};

subtest 'baf host disables COMMON' => sub {
    my $one = $CLASS->find(host => 'baf');
    is($one->algorithm,             '_redistribute_fair', "algorithm from DEFAULT fallthrough");
    is($one->max_slots,             7,                    "max_slots from host");
    is($one->max_slots_per_job,     7,                    "max_slots_per_job falls to max_slots default");
    is($one->max_slots_per_run,     7,                    "max_slots_per_run falls to max_slots default");
    is($one->default_slots_per_job, 7,                    "default_slots_per_job falls to max_slots_per_job default");
    is($one->default_slots_per_run, 7,                    "default_slots_per_run falls to max_slots_per_run default");
};

subtest 'ban has use_common=0 and no max_slots anywhere' => sub {
    like(
        dies { $CLASS->find(host => 'ban') },
        qr/'max_slots' not set in '\Q.sharedjobslots.yml\E' for host 'ban' or under 'COMMON' config/,
        "Need a value for max slots"
    );
};

subtest 'algorithm: first' => sub {
    my $one = $CLASS->find(host => 'baz');
    is($one->algorithm, '_redistribute_first', "algorithm=first resolves");
};

subtest 'missing config' => sub {
    # Point cwd at a throwaway dir well away from the fixture to make
    # sure find() returns undef instead of hitting the fixture. Chdir
    # back before the tempdir goes out of scope or File::Temp will
    # warn about not being able to remove a path while it is cwd.
    my $tmp = File::Temp->newdir();
    chdir("$tmp") or die "chdir($tmp) failed: $!";

    my $miss = $CLASS->find(base_name => 'does-not-exist-XXYYZZ.yml');
    ok(!defined $miss, "find returns undef when no config can be located");

    chdir($fixture_dir) or die "chdir($fixture_dir) failed: $!";
};

chdir($start_cwd) if $start_cwd;

done_testing;
