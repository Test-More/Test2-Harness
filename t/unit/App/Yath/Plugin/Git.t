use Test2::V0 -target => 'App::Yath::Plugin::Git';
use Test2::Util qw/CAN_THREAD CAN_REALLY_FORK CAN_FORK CAN_SIGSYS/;
# HARNESS-DURATION-SHORT

subtest NOTHING => sub {
    my $control = mock $CLASS => (
        override => [
            can_run => sub { undef },
        ],
    );

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
    my $control = mock $CLASS => (
        override => [
            can_run => sub {
                my $script = __FILE__;
                $script =~ s/\.t$/\.script/;
                return "$^X $script";
            },
        ],
    );

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
    my $control = mock $CLASS => (
        override => [
            can_run => sub {
                my $script = __FILE__;
                $script =~ s/\.t$/\.script/;
                return "$^X $script";
            },
        ],
    );

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
    my $control = mock $CLASS => (
        override => [
            can_run => sub {
                my $script = __FILE__;
                $script =~ s/\.t$/\.script/;
                return "$^X $script";
            },
        ],
    );

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

done_testing;
