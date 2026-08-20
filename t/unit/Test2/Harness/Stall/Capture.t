use Test2::V0 -target => 'Test2::Harness::Stall::Capture';
# HARNESS-DURATION-SHORT

use ok $CLASS;

use File::Temp qw/tempdir/;

sub capture {
    return $CLASS->new(workdir => tempdir(CLEANUP => 1));
}

subtest catches_usr1 => sub {
    my $one = capture();

    # Pin the signal number: it is 10 here but 30 on the BSDs and Darwin and
    # 16 on Solaris, and this subtest is about parsing the mask, not about
    # what the local number happens to be.
    my $mock = mock $CLASS => (override => [usr1_number => sub { 10 }]);

    # SigCgt is a hex mask of caught signals; with SIGUSR1 at 10 that is bit 9.
    ok($one->catches_usr1({sigcgt => '0000000000000200'}),  "usr1 caught");
    ok($one->catches_usr1({sigcgt => '0000000180014a03'}),  "usr1 among others");
    ok(!$one->catches_usr1({sigcgt => '0000000000000100'}), "a neighbouring signal is not usr1");
    ok(!$one->catches_usr1({sigcgt => '0000000000000000'}), "nothing caught");
    ok(!$one->catches_usr1({}),                             "no field at all");
    ok(!$one->catches_usr1({sigcgt => 'not-hex'}),          "unparseable");
};

# SIGUSR1's default action is to terminate. A test job sheds the handler when
# the runner restores the original %SIG, so signalling one kills a running
# test; and a pid recorded earlier may have exited and been recycled.
subtest signal_pids_refuses_anything_that_did_not_install_the_handler => sub {
    my $one = capture();

    my @killed;

    # have_proc must be forced: without it this subtest signals everything on
    # any platform that has no /proc, and this file ships to CPAN smokers.
    my $mock = mock $CLASS => (
        override => [
            have_proc   => sub { 1 },
            usr1_number => sub { 10 },
            kill_pid    => sub { push @killed => $_[1]; 1 },
        ],
    );

    my $procs = {
        100 => {pid => 100, sigcgt => '0000000000000200'},               # ours
        200 => {pid => 200, sigcgt => '0000000000000000'},               # shed it
        300 => {pid => 300, gone   => 1},                                # exited
        400 => {pid => 400, sigcgt => '0000000000000200', gone => 1},    # exited
    };

    my $sent = $one->signal_pids([100, 200, 300, 400, 500], $procs);

    is($sent,    [100], "only the process catching SIGUSR1");
    is(\@killed, [100], "and only that one was signalled");
};

subtest signal_pids_never_signals_a_process_group => sub {
    my $one = capture();

    my @killed;
    my $mock = mock $CLASS => (
        override => [
            have_proc => sub { 1 },
            kill_pid  => sub { push @killed => $_[1]; 1 },
        ],
    );

    # A negative pid means a process group to kill(), which must never happen.
    my $sent = $one->signal_pids([-1, -100, 0], {-100 => {sigcgt => '0000000000000200'}});

    is($sent,    [], "nothing signalled");
    is(\@killed, [], "kill was never called");
};

subtest process_tree_parses_a_comm_containing_spaces_and_parens => sub {
    my $one = capture();

    # /proc/PID/stat puts comm in parens and it may contain anything, so ppid
    # has to be read after the last ')'.
    my $mock = mock $CLASS => (
        override => [
            have_proc => sub { 1 },
            all_pids  => sub { [10, 11, 12] },
            read_proc => sub {
                my ($self, $pid, $what) = @_;
                return unless $what eq 'stat';
                return "10 (yath) S 1 10 10 0 -1 0"      if $pid == 10;
                return "11 (weird (name) here) S 10 1 1" if $pid == 11;
                return "12 (other) S 99 1 1"             if $pid == 12;
                return;
            },
        ],
    );

    is($one->process_tree(10), [10, 11], "found the child despite the parens in its name");
};

done_testing;
