use Test2::V0 -target => 'IPC::StateFile';
use Test2::IPC;
use File::Temp qw/tempdir/;

my $dir = tempdir('ipcstatefiletest-XXXXXX', TMPDIR => 1, CLEANUP => 1);

{
    package MyState;
    $INC{'MyState.pm'} = __FILE__;
    use parent 'IPC::StateFile';
    use Test2::Harness::Util::HashBase qw/xyz/;

    sub object_map {
        return {
            raw_data     => {shared => 1, depth => 0},
            blessed_data => {shared => 1, depth => 0},

            single_rpc => {rpc => 1, depth => 0},
            multi_rpc  => {rpc => 1, depth => 1},
            deep_rpc   => {rpc => 1, depth => 2},

            single_proc => {rpc => 1, process => 1, depth => 0},
        };
    }

    package MyRPC;
    $INC{'MyRPC.pm'} = __FILE__;
    use parent 'IPC::StateFile::RPCObject';
    use Test2::Harness::Util::HashBase qw/foo bar/;

    sub shared_fields { +{ baz => 1, bat => 1, counter => 1 } }

    sub increment {
        my $self = shift;
        $self->txn(w => sub {
            $self->set_field(counter => (1 + $self->get_field('counter') // 0));
        });
    }

    package MyProc;
    $INC{'MyProc.pm'} = __FILE__;
    use parent 'IPC::StateFile::RPCObject::Process';
    use Test2::Harness::Util::HashBase;
    use Time::HiRes qw/sleep/;

    sub shared_fields { +{ %{shift->SUPER::shared_fields()}, counter => 1 } }

    sub run {
        my $self = shift;
        for (1 .. 10) {
            $self->txn(w => sub {
                $self->set_field(counter => 1 + $self->get_field('counter'));
            });
            sleep(0.2);
        }
    }

    package MyNonRPC;
    $INC{'MyNonRPC.pm'} = __FILE__;
    use Test2::Harness::Util::HashBase qw/foo bar/;
    sub TO_JSON { +{ %{$_[0]} } }
    sub FROM_JSON { bless($_[1], $_[0]) }
}

my $fname = "$dir/a";

my $one = MyState->create($fname);
isa_ok($one, CLASS());

like(
    dies { MyState->create($fname) },
    qr/State file already exists/,
    "Cannot create it twice"
);

my $two = MyState->connect($fname);
isa_ok($two, CLASS());

subtest write_lock_blocks_read_lock => sub {
    $one->txn(
        w => sub {
            my $ran = 0;

            ok(!$two->transaction(mode => 'r', blocking => 0, cb => sub { $ran++; 1 }), "Did not run");

            ok(!$ran, "Did not run");
        }
    );
};

subtest nonblocking_read_lock_works => sub {
    my $ran = 0;

    ok($two->transaction(mode => 'r', blocking => 0, cb => sub { $ran++; 1 }), "Ran");

    ok($ran, "Did run");
};

subtest write_hooks => sub {
    my ($before, $after);
    $one->set_before_write(sub { $before = 1 });
    $one->set_after_write(sub { $before  = 1 });
    $one->txn(w => sub { 1 });
    ok($before, "Ran before hook");
    ok($before, "Ran after hook");
};

subtest invalid_types => sub {
    like(
        dies { $one->set('foo', 1) },
        qr/Unsupported type 'foo'/,
        "Not a valid type for set"
    );

    like(
        dies { $one->init('foo', 1) },
        qr/Unsupported type 'foo'/,
        "not a valid type for init"
    );

    like(
        dies { $one->get('foo') },
        qr/Unsupported type 'foo'/,
        "Not a valid type for get"
    );

    like(
        dies { $one->del('foo') },
        qr/Unsupported type 'foo'/,
        "Not a valid type for del"
    );

    like(
        dies { $one->list('foo') },
        qr/Unsupported type 'foo'/,
        "Not a valid type for list"
    );
};

subtest non_rpc_shared_data => sub {
    $one->set(raw_data => {a => {b => 'c'}});
    is($one->get('raw_data'), {a => {b => 'c'}}, "Got value in connection 1");
    is($two->get('raw_data'), {a => {b => 'c'}}, "Got value in connection 2");

    ref_is_not($two->get('raw_data'), $two->get('raw_data'), "No cache in this situation");

    my ($ref1, $ref2);
    $two->txn(
        r => sub {
            $ref1 = $two->get('raw_data');
            $ref2 = $two->get('raw_data');
            ref_is($ref1, $ref2, "Cached inside txn");
        }
    );

    ref_is_not($two->get('raw_data'), $ref1, "Cache expired after txn");

    $one->txn(w => sub { $one->get('raw_data')->{x} = 1 });
    is($two->get('raw_data')->{x}, 1, "Got updated data");

    like (
        dies { $one->set(single_rpc => 1) },
        qr/'single_rpc' is not a shared object/,
        "Incorrect type cannot be used in set"
    );

    my @list = $one->list('raw_data');
    is(@list, 1, "Got 1 item");
    is(\@list, [{a => {b => 'c'}, x => 1}], "Got item in list");

    $one->del('raw_data');
    ok(!$two->get('raw_data'), "Deleted");

    my $fname2 = "$dir/b";
    my $three = MyState->create($fname2, raw_data => {foo => 1}, xyz => 123);
    is($three->xyz, 123, "set xyz at creation");
    is($three->get('raw_data'), {foo => 1}, "set raw_data at creation");

    my $four = MyState->connect($fname2, xyz => 345);
    is($four->xyz, 345, "set xyz at creation");
    is($four->get('raw_data'), {foo => 1}, "got raw_data from creation");
};

subtest blessed_non_rpc_shared => sub {
    my $thing = MyNonRPC->new(foo => 'f1', bar => 'b1');
    $one->set(blessed_data => $thing);
    my $copy = $two->get('blessed_data');
    is($copy, $thing, "Copied data");
    isa_ok($copy, 'MyNonRPC');

    $one->txn(w => sub { $one->get('blessed_data')->set_foo('f2') });
    is($two->get('blessed_data')->foo, 'f2', "Got updated data");

    my ($ref1, $ref2);
    $two->txn(
        r => sub {
            $ref1 = $two->get('blessed_data');
            $ref2 = $two->get('blessed_data');
            ref_is($ref1, $ref2, "Cached inside txn");
        }
    );

    ref_is_not($two->get('blessed_data'), $ref1, "Cache expired after txn");

    my @list = $one->list('blessed_data');
    is(@list, 1, "Got 1 item");
    is(\@list, [$ref1], "Got item in list");

    $one->del('blessed_data');
    ok(!$two->get('blessed_data'), "Deleted");
};

sub run_fork(&) {
    my ($code) = @_;
    my $pid = fork // die "Could not fork: $!";
    return $pid if $pid;
    exit(0) if eval { $code->(); 1 };
    warn $@;
    exit(255);
}

subtest single_rpc => sub {
    my $rpc1_1 = $one->init('single_rpc', MyRPC => {foo => 'f1', bar => 'br1', baz => 'bz1', bat => 'bt1', counter => 0});
    ref_is($one->get('single_rpc'), $rpc1_1, "Cached the reference, even outside of a txn");
    my $rpc2_1 = $two->get('single_rpc');
    ref_is($two->get('single_rpc'), $rpc2_1, "Cached the reference, even outside of a txn");

    is($rpc2_1->get_field('baz'), 'bz1', "Got shared data");
    isnt($rpc2_1->foo, 'f1', "Did not share fields that are not shared");

    my @pids;
    push @pids => run_fork { $rpc1_1->increment } for 1 .. 10;
    push @pids => run_fork { $rpc2_1->increment } for 1 .. 10;
    waitpid($_, 0) for @pids;
    is($rpc1_1->get_field('counter'), 20, "Incrementing in both objects effects both objects across 20 concurrent processes");
    is($rpc2_1->get_field('counter'), 20, "Incrementing in both objects effects both objects across 20 concurrent processes");

    my @list = $one->list('single_rpc');
    is(@list, 1, "Got 1 item");

    $one->del('single_rpc');
    is($two->list('single_rpc'), 0, "Deleted (list)");
    ok(!$two->get('single_rpc'), "Deleted (get)");
};

subtest multi_rpc => sub {
    my $rpc1_A = $one->init('multi_rpc', 'A', MyRPC => {baz => 'bz1', bat => 'bt1', counter => 0});
    ref_is($one->get('multi_rpc', 'A'), $rpc1_A, "Cached the reference, even outside of a txn");
    my $rpc2_A = $two->get('multi_rpc', 'A');
    ref_is($two->get('multi_rpc', 'A'), $rpc2_A, "Cached the reference, even outside of a txn");

    my $rpc2_B = $two->init('multi_rpc', 'B', MyRPC => {baz => 'bz2', bat => 'bt2', counter => 0});
    my $rpc1_B = $one->get('multi_rpc', 'B');

    is($rpc2_A->get_field('baz'), 'bz1', "Got shared data");
    is($rpc1_B->get_field('baz'), 'bz2', "Got shared data");

    my @list = $one->list('multi_rpc');
    is(@list, 2, "Got 2 items");

    $one->del('multi_rpc', 'A');
    is($two->list('multi_rpc'), 1, "Deleted A (list)");
    ok(!$two->get('multi_rpc', 'A'), "Deleted A (get)");

    $one->del('multi_rpc');
    is($two->list('multi_rpc'), 0, "Deleted B (list)");
    ok(!$two->get('multi_rpc', 'B'), "Deleted B (get)");
};

subtest deep_rpc => sub {
    my $rpc1_A = $one->init('deep_rpc', 'x', 'A', MyRPC => {baz => 'bz1', bat => 'bt1', counter => 0});
    ref_is($one->get('deep_rpc', 'x', 'A'), $rpc1_A, "Cached the reference, even outside of a txn");
    my $rpc2_A = $two->get('deep_rpc', 'x', 'A');
    ref_is($two->get('deep_rpc', 'x', 'A'), $rpc2_A, "Cached the reference, even outside of a txn");

    my $rpc2_B = $two->init('deep_rpc', 'x', 'B', MyRPC => {baz => 'bz2', bat => 'bt2', counter => 0});
    my $rpc1_B = $one->get('deep_rpc', 'x', 'B');

    is($rpc2_A->get_field('baz'), 'bz1', "Got shared data");
    is($rpc1_B->get_field('baz'), 'bz2', "Got shared data");

    my @list = $one->list('deep_rpc');
    is(@list, 2, "Got 2 items");

    $one->del('deep_rpc', 'x', 'A');
    is($two->list('deep_rpc'), 1, "Deleted A (list)");
    ok(!$two->get('deep_rpc', 'x', 'A'), "Deleted A (get)");

    $one->del('deep_rpc');
    is($two->list('deep_rpc'), 0, "Deleted B (list)");
    ok(!$two->get('deep_rpc', 'x', 'B'), "Deleted B (get)");
};

subtest proc => sub {
    my $proc1a = $one->init('single_proc', MyProc => {counter => 0});
    is($proc1a->get_field('counter'), 0, "Set to 0");
    ok($proc1a->spawn(), "Started");

    my $pid = run_fork {
        subtest proc_part2 => sub {
            my $proc1b = $two->get('single_proc');
            like(
                dies { $proc1b->spawn() },
                qr/Process is already running/,
                "Already started"
            );

            ok($proc1b->is_running, "Running check");

            like(
                dies { $proc1b->wait },
                qr/Not process parent/,
                "Not the momma!"
            );

            while ($proc1b->is_running) {
                sleep 1;
            }

            is($proc1b->get_field('counter'), 10, "Incremented");
            is($proc1b->get_field('exit'),    0,  "Exit value set to 0");
        };
    };

    ok($proc1a->is_running, "Running check");

    $proc1a->wait;

    is($proc1a->get_field('counter'), 10, "Incremented");
    is($proc1a->get_field('exit'),    0,  "Exit value set to 0");

    waitpid($pid, 0);
};

done_testing;
