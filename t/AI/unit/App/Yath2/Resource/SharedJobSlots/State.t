use Test2::V0;
use File::Temp qw/tempfile tempdir/;

use App::Yath2::Resource::SharedJobSlots::State;

my $CLASS = 'App::Yath2::Resource::SharedJobSlots::State';

sub inst {
    my %params = @_;

    my $state_file = $params{state_file};

    unless ($state_file) {
        my $fh;
        ($fh, $state_file) = tempfile(UNLINK => 1);
        close($fh);
        # tempfile leaves an empty file; drop it so _read_state starts
        # from a fresh init_state.
        unlink $state_file;
    }

    return $CLASS->new(
        state_file        => $state_file,
        max_slots         => 10,
        max_slots_per_job => 3,
        max_slots_per_run => 9,
        runner_pid        => $$,
        %params,
    );
}

subtest 'init_checks' => sub {
    for my $field (qw/state_file max_slots max_slots_per_job max_slots_per_run/) {
        my %proto = (
            state_file        => '/dev/null',
            max_slots         => 100,
            max_slots_per_job => 5,
            max_slots_per_run => 50,
        );

        delete $proto{$field};

        like(
            dies { $CLASS->new(%proto) },
            qr/'$field' is a required attribute/,
            "Require '$field' be provided"
        );
    }

    my $one = inst();
    isa_ok($one, [$CLASS], "Created an instance");
};

subtest 'basic registration roundtrip' => sub {
    my $one   = inst(runner_id => 'one');
    my $state = $one->transaction('w');

    is($state->{runners}->{one}->{runner_id}, 'one', "Registered 'one'");
    is($state->{runners}->{one}->{seen}, T(), "Registered with a heartbeat");

    # Write lock is released after the transaction.
    ok(!exists($state->{local}->{lock}) || !defined($state->{local}->{lock}),
        "lock released post-transaction");

    my $stored = Test2::Harness2::Util::File::JSON->new(name => $one->state_file)->read;
    is($stored->{runners}->{one}->{runner_id}, 'one', "stored on disk");
};

subtest 'expired entries' => sub {
    my $one = inst(runner_id => 'one');

    ok($one->_entry_expired(undef),          "undef entry expired");
    ok($one->_entry_expired({remove => 1}),  "remove=1 expired");
    ok($one->_entry_expired({}),             "no 'seen' field expired");

    ok(!$one->_entry_expired({seen => time}),  "Recently seen, not expired");
    ok( $one->_entry_expired({seen => (time - (10 + $CLASS->TIMEOUT))}), "Old seen, expired");
};

subtest 'allocate + assign + release' => sub {
    my $one = inst(runner_id => 'one');

    # 'con' and 'job_id' are required.
    like(dies { $one->allocate_slots() }, qr/'con' is required/, "con required");
    like(dies { $one->allocate_slots(con => [1, 1]) }, qr/'job_id' is required/, "job_id required");

    # Ask for 4 slots (min=1, max=4) from a pool of 10.
    my $got = $one->allocate_slots(con => [1, 4], job_id => 'j1');
    is($got, 4, "Allocated 4 slots");

    my $assigned = $one->assign_slots(job => {job_id => 'j1', file => 't/foo.t'});
    is($assigned->{count}, 4, "Assigned count matches allocation");

    is($one->state->{runners}->{one}->{assigned}->{j1}->{count}, 4, "Assignment recorded");

    $one->release_slots(job_id => 'j1');
    is($one->state->{runners}->{one}->{assigned}->{j1}, undef, "Assignment released");
};

subtest 'multiple runners share the pool via state file' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $state_file = "$dir/state.json";

    my $one = inst(runner_id => 'one', state_file => $state_file);
    my $two = inst(runner_id => 'two', state_file => $state_file);

    $one->update_registration;
    $two->update_registration;

    my $state = $one->state;
    ok($state->{runners}->{one}, "one registered");
    ok($state->{runners}->{two}, "two registered");

    # If two removes itself, one should see it gone.
    $two->remove_registration;
    $state = $one->state;
    ok(!$state->{runners}->{two}, "two deregistered");
};

done_testing;
