use Test2::V0 -target => 'Test2::Harness::Runner::Resource::SharedJobSlots::Config';
use Test2::Harness::Runner::Resource::SharedJobSlots::Config;

my $dir = __FILE__;
$dir =~ s{Config\.t$}{}g;
chdir($dir) or die "Could not chdir ($dir): $!";

sub CONFIG {
    return {
        DEFAULT => {
            default_slots_per_run => 1,
            default_slots_per_job => 1,
        },
        COMMON => {
            algorithm             => 'fair',
            state_file            => '/tmp/yath-state-config-test',
            max_slots             => 4,
            max_slots_per_run     => 4,
            max_slots_per_job     => 2,
            default_slots_per_run => 2,
            default_slots_per_job => 2,
        },
        foo => {
            max_slots             => 13,
            max_slots_per_run     => 13,
            max_slots_per_job     => 5,
            default_slots_per_run => 3,
            default_slots_per_job => 2,
        },
        bar => {
            max_slots             => 8,
            max_slots_per_run     => 6,
            max_slots_per_job     => 2,
            default_slots_per_run => 4,
            default_slots_per_job => 2,
            state_umask           => '0077',
        },
        baz => {
            algorithm             => 'first',
            max_slots             => 64,
            max_slots_per_run     => 64,
            max_slots_per_job     => 32,
            default_slots_per_run => 64,
            default_slots_per_job => 32,
        },
        bat => undef,
        ban => {
            use_common => '0',
        },
        baf => {
            use_common => 0,
            max_slots  => 7,
        },
    };
}

my $one = $CLASS->find(host => 'foo');

like(
    $one,
    hash {
        field host        => 'foo';
        field common_conf => CONFIG()->{COMMON};
        field host_conf   => CONFIG()->{foo};
        field config_file => '.sharedjobslots.yml';
        field config_raw  => CONFIG();
        etc;
    },
    "Found the config file, loaded options"
);

is($one->state_umask,           0007,                          "Got default umask");
is($one->state_file,            '/tmp/yath-state-config-test', "Got state file from common");
is($one->algorithm,             '_redistribute_fair',          "got algorithm from common");
is($one->max_slots,             13,                            "got max slots from host");
is($one->min_slots_per_run,     0,                             "default min slots per run at 0");
is($one->max_slots_per_job,     5,                             "got max slots per job from host");
is($one->max_slots_per_run,     13,                            "got max slots per run from host");
is($one->default_slots_per_job, 2,                             "got default slots per job from host");
is($one->default_slots_per_run, 3,                             "got default slots per run from host");

$one = $CLASS->find(host => 'bar');
is($one->state_umask, '0077', "Got host umask");

$one = $CLASS->find(host => 'bat');
is($one->algorithm,             '_redistribute_fair', "got algorithm from common");
is($one->max_slots,             4,                    "got max slots from common");
is($one->min_slots_per_run,     0,                    "default min slots per run at 0");
is($one->max_slots_per_job,     2,                    "got max slots per job from common");
is($one->max_slots_per_run,     4,                    "got max slots per run from common");
is($one->default_slots_per_job, 2,                    "got default slots per job from common");
is($one->default_slots_per_run, 2,                    "got default slots per run from common");

$one = $CLASS->find(host => 'baf');
is($one->algorithm,             '_redistribute_fair', "got algorithm from default");
is($one->max_slots,             7,                    "got max slots from host");
is($one->min_slots_per_run,     0,                    "default min slots per run at 0");
is($one->max_slots_per_job,     7,                    "got max slots per job from default");
is($one->max_slots_per_run,     7,                    "got max slots per run from default");
is($one->default_slots_per_job, 7,                    "got default slots per job from default");
is($one->default_slots_per_run, 7,                    "got default slots per run from default");

is(
    dies { $one = $CLASS->find(host => 'ban') },
    "'max_slots' not set in '\.sharedjobslots\.yml' for host 'ban' or under 'COMMON' config.\n",
    "Need a value for max slots"
);

done_testing;
