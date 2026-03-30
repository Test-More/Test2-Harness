use Test2::V0 -target => 'Test2::Harness::Reloader';

# The base class redirects new() to a subclass (Stat or Inotify2).
# We test the base class behaviour directly by bypassing the new() redirect.

subtest changed_files_is_abstract => sub {
    # Construct a raw base-class object by bypassing the overridden new()
    my $obj = bless { stage_name => 'test', restrict => [], watches => {}, watched => {} }, CLASS;
    like(
        dies { $obj->changed_files },
        qr/does not implement/,
        "changed_files croaks in base class"
    );
};

subtest new_dispatches_to_subclass => sub {
    # When constructing CLASS directly it should return a Stat or Inotify2 object.
    my $obj = CLASS->new(stage_name => 'mytest');
    ok($obj, "new returned an object");
    ok(
        $obj->isa('Test2::Harness::Reloader::Stat') ||
        $obj->isa('Test2::Harness::Reloader::Inotify2'),
        "dispatched to a concrete subclass"
    );
};

subtest init_stage_name_from_string => sub {
    my $obj = bless {}, CLASS;
    $obj->{stage} = 'mystage';
    $obj->init;
    is($obj->stage_name, 'mystage', "stage_name set from string stage");
};

subtest init_defaults => sub {
    my $obj = bless { stage_name => 'x' }, CLASS;
    $obj->init;
    is(ref($obj->{restrict}), 'ARRAY', "restrict initialized to arrayref");
    is(ref($obj->{watches}),  'HASH',  "watches initialized to hashref");
    is(ref($obj->{watched}),  'HASH',  "watched initialized to hashref");
};

subtest should_watch => sub {
    my $obj = bless { restrict => [], stage_name => 'test' }, CLASS;
    $obj->init;

    ok($obj->should_watch('/some/path/file.pm'), "no restrict means always watch");

    $obj->{restrict} = ['/allowed/'];
    ok($obj->should_watch('/allowed/foo.pm'),   "file under allowed dir is watched");
    ok(!$obj->should_watch('/other/foo.pm'),    "file outside allowed dir is not watched");
};

subtest stop => sub {
    my $obj = bless { stage_name => 'test', restrict => [], watches => {}, watched => { '/fake' => 1 } }, CLASS;
    $obj->stop;
    is(ref($obj->{watched}), 'HASH', "watched is still a hashref after stop");
    is(scalar keys %{$obj->{watched}}, 0, "watched is empty after stop");
};

subtest set_active_and_ACTIVE => sub {
    # Reset active state
    {
        no warnings 'once';
        $Test2::Harness::Reloader::ACTIVE = undef;
    }

    my $obj = bless { stage_name => 'active_test', restrict => [], watches => {}, watched => {} }, CLASS;
    is(CLASS->ACTIVE, undef, "no active reloader initially");

    $obj->set_active;
    ok(CLASS->ACTIVE, "ACTIVE returns the reloader after set_active");

    # Cleanup
    {
        no warnings 'once';
        $Test2::Harness::Reloader::ACTIVE = undef;
    }
};

done_testing;
