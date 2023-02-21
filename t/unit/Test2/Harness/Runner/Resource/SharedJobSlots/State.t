use Test2::V0 -target => 'Test2::Harness::Runner::Resource::SharedJobSlots::State';
use File::Temp qw/tempfile/;

use ok $CLASS;

sub inst {
    my %params = @_;

    my $state_file = $params{state_file};

    unless ($state_file) {
        my $fh;
        ($fh, $state_file) = tempfile(UNLINK => 1);
        close($fh);
    }

    return $CLASS->new(
        state_file        => $state_file,
        max_slots         => 10,
        max_slots_per_job => 3,
        max_slots_per_run => 9,
        access_pid        => $$,
        %params,
    );
}

subtest init_checks => sub {
    for my $field (qw/state_file max_slots max_slots_per_job max_slots_per_run/) {
        my %proto = (
            state_file        => '/dev/null',
            max_slots         => 100,
            max_slots_per_job => 5,
            max_slots_per_run => 50,
        );

        # Remove the field we are testing for.
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

subtest runner_todo => sub {
    my $one = inst(access_id => 'one');

    my $entry = {};
    is($one->_runner_todo($entry), undef, "Nothing to do");
    is($one->_runner_todo($entry, 'j1'), undef, "Nothing to do");

    is($one->_runner_todo($entry, j1 => 2), 2, "Got job count");
    is($entry->{todo}, 2, "todo is set");

    is($one->_runner_todo($entry, j2 => 3), 3, "Got job count");
    is($entry->{todo}, 5, "todo is set");

    is($one->_runner_todo($entry, j3 => 1), 1, "Got job count");
    is($entry->{todo}, 6, "todo is set");

    is($one->_runner_todo($entry, 'j2'), 3, "Got job count");
    is($entry->{todo}, 6, "todo is set");

    is($one->_runner_todo($entry, j2 => -1), 3, "Got job count");
    is($entry->{todo}, 3, "todo is set");
};

subtest _runner_calcs => sub {
    my $one = inst(access_id => 'one');

    my $r = {
        _calc_cache => "cache!",
        max_slots   => 100,
        assigned    => {1 => {count => 1}, 2 => {count => 2}},
        allocated   => 3,
        todo        => 101,
    };

    is($one->_runner_calcs($r), "cache!", "Get cache if it is present");

    delete $r->{_calc_cache};

    is(
        $one->_runner_calcs($r),
        {
            max      => 9,      # Use the global max as runner max is too high
            assigned => 3,
            active   => 6,      # Assigned + Allocated
            total    => 107,    # Active + TODO
            wants    => 9,      # We have more tests than slots, so we want the max
        },
        "Calculated data",
    );
    ok($r->{_calc_cache}, "Have a cache");
    is($one->_runner_calcs($r), $r->{_calc_cache}, "Result matches cache");
    $r->{_calc_cache}->{xxx} = 'added';
    is($one->_runner_calcs($r), $r->{_calc_cache}, "Result matches cache");
    is($one->_runner_calcs($r)->{xxx}, 'added', "Extra cache key found");

    $r = {
        max_slots   => 5,
        assigned    => {1 => {count => 2}, 2 => {count => 2}},
        allocated   => 0,
        todo        => 101,
    };
    is(
        $one->_runner_calcs($r),
        {
            max      => 5,      # Use our max, less than the global
            assigned => 4,
            active   => 4,      # Assigned + Allocated
            total    => 105,    # Active + TODO
            wants    => 5,      # We want our max
        },
        "Calculated data",
    );

    $r = {
        assigned  => {1 => {count => 5}, 2 => {count => 5}},
        allocated => 2,
        todo      => 101,
    };
    is(
        $one->_runner_calcs($r),
        {
            max      => 9,
            assigned => 10,
            active   => 12,     # Assigned + Allocated
            total    => 113,    # Active + TODO
            wants    => 12,     # We want what we are already using, even though it is higher than max.
        },
        "Calculated data",
    );
};

subtest allocate_slots => sub {
    my $one = inst(access_id => 'one');

    like(dies { $one->allocate_slots(todo => 1) }, qr/'con' is required/, "con must be specified");

    $one->{max_slots_per_job} = 10; $one->{my_max_slots_per_job} = 11; $one->{max_slots} = 11;
    like(
        dies { $one->allocate_slots(con => [11, 11], todo => 100) },
        qr/Slot request exceeds max slots per job \(11 vs \(10 || 11 || 11\)\)/,
        "Cannot exceed slot limits A"
    );

    $one->{max_slots_per_job} = 11; $one->{my_max_slots_per_job} = 10; $one->{max_slots} = 11;
    like(
        dies { $one->allocate_slots(con => [11, 11], todo => 100) },
        qr/Slot request exceeds max slots per job \(11 vs \(11 || 10 || 11\)\)/,
        "Cannot exceed slot limits B"
    );

    $one->{max_slots_per_job} = 11; $one->{my_max_slots_per_job} = 11; $one->{max_slots} = 10;
    like(
        dies { $one->allocate_slots(con => [11, 11], todo => 100) },
        qr/Slot request exceeds max slots per job \(11 vs \(11 || 11 || 10\)\)/,
        "Cannot exceed slot limits C"
    );

    $one->transaction(rw => sub {
        my ($self, $state) = @_;

        # Make sure we have an allocation so we do not trigger a redistribute.
        $state->{runners}->{one}->{todo} = 0; # To silence a warning
        $state->{runners}->{one}->{allocated} = 5;
        $state->{runners}->{one}->{allotment} = 2;

        # Do calcs and cache them so we can verify they get cleared.
        my $calcs = $self->_runner_calcs($state->{runners}->{one});
        $calcs->{CACHED} = 1;
    });

    ok($one->state->{runners}->{one}->{_calc_cache}->{CACHED}, "runner calc cache is as expected", $one->state->{runners}->{one}->{_calc_cache});
    is($one->state->{runners}->{one}->{allocated}, 5, "Allocation is 5");
    is($one->allocate_slots(con => [4, 4], job_id => '123'), 4, "We got 4 slots!");
    ok(!$one->state->{runners}->{one}->{_calc_cache}->{CACHED}, "Allocating slots reset runner calc cache", $one->state->{runners}->{one}->{_calc_cache});
    is($one->state->{runners}->{one}->{allocated}, 4, "Allocation updated to 4");
};

done_testing;

__END__

TODO do more testing on this

sub _allocate_slots {
    my $self = shift;
    my ($state, %params) = @_;

    my $entry = $state->{runners}->{$self->{+RUNNER_ID}};
    delete $entry->{_calc_cache};

    my $count  = $params{count};
    my $job_id = $params{job_id};
    $self->_runner_todo($entry, $job_id => $count);

    my $allocated = $entry->{allocated};

    # We have what we need already allocated
    return $entry->{allocated} = $count
        if $count <= $allocated;

    # Our allocation, if any, is not big enough, free it so we do not have a
    # deadlock with all runner holding an insufficient allocation.
    $allocated = $entry->{allocated} = 0;

    my $calcs = $self->_runner_calcs($entry);

    for (0 .. 1) {
        $self->_redistribute($state) if $_; # Only run on second loop

        # Cannot do anything if we have no allotment or no available slots.
        # This will go to the next loop for a redistribution, or end the loop.
        my $allotment = $entry->{allotment}             or next;
        my $available = $allotment - $calcs->{assigned} or next;

        # If our allotment is lower than the count we may end up never getting
        # enough, so we forcefully reduce the count.
        # We do this for busy systems where the pool is too small to meet the
        # request. But we do not reduce the count to the available level,
        # availability can change to match the allotment.
        my $c = min($allotment, $count);

        next unless $available >= $c;
        return $entry->{allocated} = $c;
    }

    return 0;
}

sub assign_slots {
    my $self = shift;
    my (%params) = @_;

    my $job = $params{job} or croak "'job' is required";

    return $self->transaction(rw => '_assign_slots', job => $job);
}

sub _assign_slots {
    my $self = shift;
    my ($state, %params) = @_;

    my $entry = $state->{runners}->{$self->{+RUNNER_ID}};
    delete $entry->{_calc_cache};

    my $job       = $params{job};
    my $job_id    = $job->{job_id};
    my $allocated = $entry->{allocated};

    my $count = $self->_runner_todo($entry, $job_id => -1);

    $job->{count} = $count;
    $job->{started} = time;

    $entry->{allocated} = 0;

    $entry->{assigned}->{$job->{job_id}} = $job;

    return $job;
}

sub release_slots {
    my $self = shift;
    my (%params) = @_;

    my $job_id = $params{job_id} or croak "'job_id' is required";

    return $self->transaction(rw => '_release_slots', job_id => $job_id);
}

sub _release_slots {
    my $self = shift;
    my ($state, %params) = @_;

    my $entry = $state->{runners}->{$self->{+RUNNER_ID}};

    my $job_id = $params{job_id};

    delete $entry->{assigned}->{$job_id};
    delete $entry->{_calc_cache};

    $self->_runner_todo($entry, $job_id => -1);

    # Reduce our allotment if it makes sense to do so.
    my $calcs = $self->_runner_calcs($entry);
    $entry->{allotment} = $calcs->{total} if $entry->{allotment} > $calcs->{total};
}

sub _redistribute {
    my $self = shift;
    my ($state) = @_;

    my $max_run = $self->{+MAX_SLOTS_PER_RUN};

    my $wanted = 0;
    for my $runner (values %{$state->{+RUNNERS}}) {
        my $calcs = $self->_runner_calcs($runner);
        $runner->{allotment} = $calcs->{wants};
        $wanted += $calcs->{wants};
    }

    # Everyone gets what they want!
    my $max = $self->{+MAX_SLOTS};
    return if $wanted <= $max;

    my $meth = $self->{+ALGORITHM};

    return $self->$meth($state);
}

sub _redistribute_first {
    my $self = shift;
    my ($state) = @_;

    my $min = $self->{+MIN_SLOTS_PER_RUN};
    my $max = $self->{+MAX_SLOTS};

    my $c = 0;
    for my $runner (sort { $a->{added} <=> $b->{added} } values %{$state->{+RUNNERS}}) {
        my $calcs = $self->_runner_calcs($runner);
        my $wants = $calcs->{wants};

        if ($max >= $wants) {
            $runner->{allotment} = $wants;
        }
        else {
            $runner->{allotment} = max($max, $min, 0);
        }

        $max -= $runner->{allotment};

        $c++;
    }

    return;
}

sub _redistribute_fair {
    my $self = shift;
    my ($state) = @_;

    my $runs = scalar keys %{$state->{+RUNNERS}};

    # Avoid a divide by 0 below.
    return unless $runs;

    my $total = $self->{+MAX_SLOTS};
    my $min   = $self->{+MIN_SLOTS_PER_RUN};

    my $used = 0;
    for my $runner (values %{$state->{+RUNNERS}}) {
        my $calcs = $self->_runner_calcs($runner);

        # We never want less than the 'active' number
        my $set = $calcs->{active};

        # If min is greater than the active number and there are todo tests, we
        # use the min instead.
        $set = $min if $set < $min && $runner->todo;

        $runner->{allotment} = $set;
        $used += $set;
    }

    my $free = $total - $used;
    return unless $free >= 1;

    # Is there a more efficient way to do this? Yikes!
    my @runners = values %{$state->{+RUNNERS}};
    while ($free > 0) {
        @runners = sort { $a->{allotment} <=> $b->{allotment} || $a->{added} <=> $b->{added} }
                   grep { my $c = $self->_runner_calcs($_); $c->{wants} > $_->{allotment} }
                   @runners;

        $free--;
        $runners[0]->{allotment}++;
    }

    return;
}


