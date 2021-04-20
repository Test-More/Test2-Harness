use Test2::V0 -target => 'App::Yath::Plugin::Git';
use Test2::Util qw/CAN_THREAD CAN_REALLY_FORK CAN_FORK CAN_SIGSYS/;
# HARNESS-DURATION-SHORT

use Test2::Harness::Settings;

subtest NOTHING => sub {
    my $control = mock $CLASS => (
        override => [
            can_run => sub { undef  },
            git_cmd => sub { return },
        ],
    );

    local $ENV{GIT_COMMAND};
    local $ENV{GIT_LONG_SHA};
    local $ENV{GIT_SHORT_SHA};
    local $ENV{GIT_STATUS};
    local $ENV{GIT_BRANCH};

    my $meta   = {};
    my $fields = [];
    $CLASS->inject_run_data(meta => $meta, fields => $fields);

    ok(!$meta->{git}, "no git added to meta");
    is(@$fields, 0, "No fields added");
};

subtest ENV => sub {
    my $script = __FILE__;
    $script =~ s/\.t$/\.script/;
    local $ENV{GIT_COMMAND} = $script;
    local $ENV{GIT_LONG_SHA}  = "1230988f2c2bd26a1691a82766d5bf5c7524b123";
    local $ENV{GIT_SHORT_SHA} = "1230988";
    local $ENV{GIT_STATUS}    = " M lib/App/Yath/Command.pm";
    local $ENV{GIT_BRANCH}    = "my.super-long-branch-name-needs-to-be-trimmed";

    my $meta   = {};
    my $fields = [];
    $CLASS->inject_run_data(meta => $meta, fields => $fields);

    is(
        $meta,
        {
            git => {
                branch => 'my.super-long-branch-name-needs-to-be-trimmed',
                sha    => '1230988f2c2bd26a1691a82766d5bf5c7524b123',
                status => ' M lib/App/Yath/Command.pm',
            },
        },
        "Added git info to meta-data"
    );

    is(
        $fields,
        [
            {
                data    => $meta->{git},
                details => 'my.super-long-branch',
                name    => 'git',
                raw     => 'my.super-long-branch-name-needs-to-be-trimmed',
            }
        ],
        "Added git field",
    );
};

subtest CMD => sub {
    my $script = __FILE__;
    $script =~ s/\.t$/\.script/;
    local $ENV{GIT_COMMAND} = $script;
    local $ENV{GIT_LONG_SHA};
    local $ENV{GIT_SHORT_SHA};
    local $ENV{GIT_STATUS};
    local $ENV{GIT_BRANCH};

    my $meta   = {};
    my $fields = [];
    $CLASS->inject_run_data(meta => $meta, fields => $fields);

    is(
        $meta,
        {
            git => {
                branch => 'my.branch.foo',
                sha    => '4570988f2c2bd26a1691a82766d5bf5c7524bcea',
                status => ' M lib/App/Yath/Plugin/Git.pm',
            },
        },
        "Added git info to meta-data"
    );

    is(
        $fields,
        [
            {
                data    => $meta->{git},
                details => 'my.branch.foo',
                name    => 'git',
                raw     => 'my.branch.foo',
            }
        ],
        "Added git field",
    );
};

subtest MIX => sub {
    my $script = __FILE__;
    $script =~ s/\.t$/\.script/;
    local $ENV{GIT_COMMAND} = $script;
    local $ENV{GIT_LONG_SHA} = "1230988f2c2bd26a1691a82766d5bf5c7524b123";
    local $ENV{GIT_SHORT_SHA};
    local $ENV{GIT_STATUS};
    local $ENV{GIT_BRANCH};

    my $meta   = {};
    my $fields = [];
    $CLASS->inject_run_data(meta => $meta, fields => $fields);

    is(
        $meta,
        {
            git => {
                branch => 'my.branch.foo',
                sha    => '1230988f2c2bd26a1691a82766d5bf5c7524b123',
                status => ' M lib/App/Yath/Plugin/Git.pm',
            },
        },
        "Added git info to meta-data"
    );

    is(
        $fields,
        [
            {
                data    => $meta->{git},
                details => 'my.branch.foo',
                name    => 'git',
                raw     => 'my.branch.foo',
            }
        ],
        "Added git field",
    );
};

subtest changed_files => sub {
    my $settings = Test2::Harness::Settings->new();
    $settings->define_prefix('git');
    $settings->git->vivify_field('change_base');

    my $script = __FILE__;
    $script =~ s/\.t$/\.script/;
    local $ENV{GIT_COMMAND} = $script;

    is(
        [$CLASS->changed_files($settings)],
        [['a.file', '*', 'sub1', 'sub3']],
        "Got changed file"
    );

    $settings->git->field(change_base => 'master');
    is(
        [$CLASS->changed_files($settings)],
        [
            ['a.file', '*', 'sub1', 'sub3'],
            ['b.file', '*', 'sub1'],
            ['c.file', 'sub1'],
        ],
        "Got changed files from change_base"
    );
};

done_testing;
