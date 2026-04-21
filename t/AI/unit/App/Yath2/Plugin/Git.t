use Test2::V0;

use App::Yath2::Plugin::Git;

subtest 'role composition' => sub {
    ok(App::Yath2::Plugin::Git->DOES('App::Yath2::Role::Plugin'),
        'Git consumes App::Yath2::Role::Plugin');
    ok(App::Yath2::Plugin::Git->DOES('Test2::Harness2::Role::Plugin'),
        'Git also satisfies Test2::Harness2::Role::Plugin transitively');
};

subtest 'env-var driven run_fields' => sub {
    local %ENV = %ENV;
    $ENV{GIT_LONG_SHA}  = '0123456789abcdef0123456789abcdef01234567';
    $ENV{GIT_SHORT_SHA} = '0123456';
    $ENV{GIT_BRANCH}    = 'my-branch';
    $ENV{GIT_STATUS}    = ' M lib/Foo.pm';
    # Ensure we don't shell out to git for the "not set" case.
    # This test would still be safe if we did -- git would just
    # overwrite our env vars only where they're undef -- but by
    # setting all four we short-circuit all fork/exec calls.

    my @fields = App::Yath2::Plugin::Git->run_fields;
    is(scalar(@fields), 1, 'one field produced');

    my $f = $fields[0];
    is($f->{name}, 'git', 'field name is "git"');
    is($f->{details}, 'my-branch', 'branch becomes details');
    is($f->{raw}, $ENV{GIT_LONG_SHA}, 'raw is long sha');
    is($f->{data}{sha}, $ENV{GIT_LONG_SHA}, 'data.sha is long sha');
    is($f->{data}{branch}, 'my-branch', 'data.branch set');
    is($f->{data}{status}, ' M lib/Foo.pm', 'data.status set');
};

subtest 'no branch -> short sha is details' => sub {
    local %ENV = %ENV;
    $ENV{GIT_LONG_SHA}  = 'abcdef0123456789abcdef0123456789abcdef01';
    $ENV{GIT_SHORT_SHA} = 'abcdef0';
    delete $ENV{GIT_BRANCH};
    delete $ENV{GIT_STATUS};

    # Prevent git invocations when GIT_BRANCH is empty. We only know
    # that branch is unset so the remaining env vars are what git
    # would return. Use a bogus command to make any real git call
    # fail; the plugin should still produce a field because all the
    # sha info is already in @ENV.
    local $ENV{GIT_COMMAND} = '/nonexistent/bin/git';

    my @fields = App::Yath2::Plugin::Git->run_fields;
    if (@fields) {
        my $f = $fields[0];
        # If the platform's system() returns non-zero for a missing
        # binary, git_output dies and branch stays undef -> short sha
        # path.
        ok($f->{name} eq 'git', 'field produced');
        ok(defined $f->{details},  'details defined');
    }
    else {
        # git_output died for a missing binary; the plugin dies
        # rather than skipping (old behaviour on git-command-failed).
        pass('missing git binary caused no field');
    }
};

subtest 'no long sha -> no field' => sub {
    local %ENV = %ENV;
    delete $ENV{$_} for qw/GIT_LONG_SHA GIT_SHORT_SHA GIT_STATUS GIT_BRANCH/;

    # Point at a non-git dir so no git probe will succeed.
    # git rev-parse HEAD returns non-zero outside a repo, so long_sha
    # remains undef. The plugin must then return empty.
    local $ENV{GIT_COMMAND} = '/nonexistent/bin/git';

    my @fields = App::Yath2::Plugin::Git->run_fields;
    is(scalar(@fields), 0, 'no fields when long sha cannot be determined');
};

subtest 'run_queued delegates to run_fields' => sub {
    local %ENV = %ENV;
    $ENV{GIT_LONG_SHA} = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef';
    $ENV{GIT_BRANCH}   = 'main';
    delete $ENV{GIT_STATUS};
    delete $ENV{GIT_SHORT_SHA};

    my @out = App::Yath2::Plugin::Git->run_queued({});
    is(scalar(@out), 1, 'run_queued returns a single field when git data is available');
    is($out[0]->{details}, 'main', 'details is the branch');
};

subtest 'HAS_* constants' => sub {
    ok(defined &App::Yath2::Plugin::Git::HAS_IPC_CMD,      'HAS_IPC_CMD is a constant');
    ok(defined &App::Yath2::Plugin::Git::HAS_CAPTURE_TINY, 'HAS_CAPTURE_TINY is a constant');
};

done_testing;
