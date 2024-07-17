use Test2::V0 -target => 'App::Yath::Plugin::Git';
use Test2::Util qw/CAN_THREAD CAN_REALLY_FORK CAN_FORK CAN_SIGSYS/;
# HARNESS-DURATION-SHORT

use Getopt::Yath::Settings;

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

    my @fields = $CLASS->run_fields();
    is(@fields, 0, "No fields added");
};

subtest ENV => sub {
    my $script = __FILE__;
    $script =~ s/\.t$/\.script/;
    local $ENV{GIT_COMMAND} = $script;
    local $ENV{GIT_LONG_SHA}  = "1230988f2c2bd26a1691a82766d5bf5c7524b123";
    local $ENV{GIT_SHORT_SHA} = "1230988";
    local $ENV{GIT_STATUS}    = " M lib/App/Yath/Command.pm";
    local $ENV{GIT_BRANCH}    = "my.super-long-branch-name";

    my @fields = $CLASS->run_fields();

    is(
        \@fields,
        [{
            data => {
                branch => 'my.super-long-branch-name',
                sha    => '1230988f2c2bd26a1691a82766d5bf5c7524b123',
                status => ' M lib/App/Yath/Command.pm',
            },
            details => 'my.super-long-branch-name',
            name    => 'git',
            raw     => '1230988f2c2bd26a1691a82766d5bf5c7524b123',
        }],
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

    my @fields = $CLASS->run_fields();

    is(
        \@fields,
        [{
            data => {
                branch => 'my.branch.foo',
                sha    => '4570988f2c2bd26a1691a82766d5bf5c7524bcea',
                status => ' M lib/App/Yath/Plugin/Git.pm',
            },
            details => 'my.branch.foo',
            name    => 'git',
            raw     => '4570988f2c2bd26a1691a82766d5bf5c7524bcea',
        }],
        "Added git field",
    );
};

subtest MIX => sub {
    my $script = __FILE__;
    $script =~ s/\.t$/\.script/;
    local $ENV{GIT_COMMAND}  = $script;
    local $ENV{GIT_LONG_SHA} = "1230988f2c2bd26a1691a82766d5bf5c7524b123";
    local $ENV{GIT_SHORT_SHA};
    local $ENV{GIT_STATUS};
    local $ENV{GIT_BRANCH};

    my @fields = $CLASS->run_fields();

    is(
        \@fields,
        [{
            data => {
                branch => 'my.branch.foo',
                sha    => '1230988f2c2bd26a1691a82766d5bf5c7524b123',
                status => ' M lib/App/Yath/Plugin/Git.pm',
            },
            details => 'my.branch.foo',
            name    => 'git',
            raw     => '1230988f2c2bd26a1691a82766d5bf5c7524b123',
        }],
        "Added git field",
    );
};

subtest changed_files => sub {
    my $settings = Getopt::Yath::Settings->new();
    $settings->create_group('git');
    $settings->git->create_option('change_base');

    my $script = __FILE__;
    $script =~ s/\.t$/\.script/;
    local $ENV{GIT_COMMAND} = $script;

    require App::Yath::Finder;
    my $finder = App::Yath::Finder->new();

    my ($type, $data) = $CLASS->changed_diff($settings);
    is(
        [$finder->changes_from_diff($type, $data)],
        [],
        "No Changes"
    );

    $settings->git->option(change_base => 'master');
    ($type, $data) = $CLASS->changed_diff($settings);
    is(
        [$finder->changes_from_diff($type, $data)],
        [
            ['a.file', '*', 'sub1', 'sub3'],
            ['b.file', '*', 'sub1'],
            ['c.file', 'sub1'],
        ],
        "Got changed files from change_base"
    );
};

done_testing;
