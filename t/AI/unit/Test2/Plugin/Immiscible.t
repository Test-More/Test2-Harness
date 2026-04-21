use Test2::V0;
use File::Temp qw/tempdir/;

# Run Test2::Plugin::Immiscible in a child process so its plan-based
# SKIP control-flow doesn't hijack our own test plan. For each
# scenario we fork, import the plugin there with the appropriate
# callback / env, and inspect the child's output + exit status.
#
# NOTE: we deliberately do NOT `use Test2::Plugin::Immiscible` here
# at the top of this test -- that would acquire the immiscibility
# lock in the caller's cwd. All probing happens via run_child so the
# plugin's side effects stay in a throwaway tempdir.

use Cwd ();
use Test2::Plugin::Immiscible ();

# Absolute lib path captured BEFORE any subtest cd's into a tempdir so
# the child can still locate our Test2/Formatter/Stream2.pm once the
# T2_FORMATTER=Stream2 env we inherit from the outer yath collector
# triggers a lazy require. Without the absolute path the child's
# `-I lib` is relative to the tempdir and Stream2 can't be found.
my $ABS_LIB = Cwd::abs_path('lib') // 'lib';

sub run_child {
    my ($perl_code, %opts) = @_;
    my $dir = $opts{cwd};

    my $script = File::Temp->new(SUFFIX => '.pl');
    print $script "use strict; use warnings; use Test2::V0;\n";
    print $script $perl_code;
    close $script;

    # Clear the harness-injected formatter env so the child emits
    # plain TAP / plugin notes, not Stream2 JSON frames. Under yath
    # the outer collector sets these; under prove they are unset.
    # This test greps for human-readable strings either way.
    local %ENV = %ENV;
    delete $ENV{T2_FORMATTER};
    delete $ENV{T2_HARNESS2_PIPE_COUNT};

    my $cmd_dir = $dir ? "cd '$dir' && " : '';
    my $out = qx{$cmd_dir $^X -I '$ABS_LIB' $script 2>&1};
    return {out => $out, exit => $?};
}

subtest 'skip callback bypasses enforcement' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $res = run_child(<<'EOT', cwd => $dir);
use Test2::Plugin::Immiscible(sub { 1 });
ok(1, "unblocked");
done_testing;
EOT
    like($res->{out}, qr/Immiscibility enforcement skipped/, 'skip note emitted');
    is($res->{exit}, 0, 'child exits cleanly');
};

subtest 'acquires lock in a writable cwd' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $res = run_child(<<'EOT', cwd => $dir);
use Test2::Plugin::Immiscible;
ok(1, "ran");
done_testing;
EOT
    like($res->{out}, qr/Immiscibility enforcement success/,
        'success note emitted when lock acquired');
    is($res->{exit}, 0, 'child exits cleanly');

    ok(-f "$dir/.immiscible-test.lock", 'lock file created');
};

subtest 'skips when cwd is not writable' => sub {
    my $dir = tempdir(CLEANUP => 1);
    chmod 0555, $dir;

    my $res = run_child(<<'EOT', cwd => $dir);
use Test2::Plugin::Immiscible;
ok(1, "should not run");
done_testing;
EOT
    chmod 0755, $dir;    # restore so cleanup works

    like($res->{out}, qr/'\.' is not writable, cannot guarentee immiscibility/,
        'SKIP reason surfaced');
};

done_testing;
