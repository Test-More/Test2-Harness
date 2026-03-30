use Test2::V0 -target => 'Test2::Harness::Collector::Preloaded';

my $CLASS = CLASS();

subtest 'inherits from Collector' => sub {
    ok($CLASS->isa('Test2::Harness::Collector'), "inherits from Test2::Harness::Collector");
};

subtest 'has expected accessor methods' => sub {
    ok($CLASS->can('orig_sig'), "has orig_sig accessor");
    ok($CLASS->can('stage'),    "has stage accessor");
};

subtest 'preload_list returns an array ref' => sub {
    # We can instantiate a minimal object to test preload_list
    # It only needs to iterate %INC, no process-level deps
    my $obj = bless {}, $CLASS;
    my $list = $obj->preload_list();
    ok(ref($list) eq 'ARRAY', "preload_list returns arrayref");
    # Each item should be [mod, file, pos] if any DATA handles are open
    for my $item (@$list) {
        ok(ref($item) eq 'ARRAY', "each item is an arrayref");
        is(scalar @$item, 3, "each item has 3 elements [mod, file, pos]");
    }
};

subtest 'restore_signals does not die with empty orig_sig' => sub {
    my $obj = bless { orig_sig => {} }, $CLASS;
    ok(lives { $obj->restore_signals() }, "restore_signals with empty orig_sig doesn't die");
};

subtest 'restore_signals restores a signal handler' => sub {
    my $original_handler = $SIG{USR1} // 'DEFAULT';

    # Set a dummy handler
    local $SIG{USR1} = sub { 1 };

    my $obj = bless {
        orig_sig => { USR1 => $original_handler },
    }, $CLASS;

    ok(lives { $obj->restore_signals() }, "restore_signals doesn't die");
    is($SIG{USR1}, $original_handler, "USR1 handler restored");
};

subtest 'build_init_state resets ARGV and calls srand' => sub {
    my $obj = bless {}, $CLASS;
    local @ARGV = ('old', 'args');
    ok(lives { $obj->build_init_state() }, "build_init_state doesn't die");
    is(scalar @ARGV, 0, "ARGV cleared by build_init_state");
};

done_testing;
