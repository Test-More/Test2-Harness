use Test2::V0 -target => 'Test2::Harness::Runner::Resource::SharedJobSlots::State';
use File::Temp qw/tempfile/;
use Test2::Plugin::BailOnFail;

use ok $CLASS;

sub inst {
    my %params = @_;

    my $state_file = $params{state_file};

    unless ($state_file) {
        my $fh;
        ($fh, $state_file) = tempfile();
        close($fh);
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

subtest init_state => sub {
    my $one   = inst(runner_id => 'one');
    my $state = $one->transaction('w');
    like(
        $state,
        {
            assigned => {},
            queue    => {},
            pending  => [],
            ords     => {runners => 2, pending => 1},    # Runners has been incremented
            runners  => {
                one => {runner_id => 'one', ord => 1},    # The runner added for our transacton
            },
        },
        "Got initial state"
    );

    # Remove the local data (not stored)
    my $local = delete $state->{local};
    like(
        $local,
        {
            lock      => FDNE,                            # The lock should not be present anymore (it is weakened inside the transaction, gone after)
            used      => {__ALL__ => 0},                  # No slots used
            available => 10,                              # none used, have all 10
            write     => T,                               # This was a write transaction
            pending   => {release => 0, request => 0},    # No slots pending in either direction
        },
        "Local data is as expected",
    );

    my $stored = Test2::Harness::Util::File::JSON->new(name => $one->state_file)->read;
    is($state, $stored, "state and stored match");
};

subtest transaction => sub {
    my $one = inst(runner_id => 'one');

    my $end_state = $one->transaction(
        w => sub {
            my ($the_one, $state, @args) = @_;

            ref_is($the_one, $one, "Got the instance first");
            ref_ok($state, 'HASH', "got a hash");
            is(\@args, [qw/arg1 arg2/], "Got additional args");

            my $local_check = {
                lock  => T(),
                write => T(),
                mode  => 'w',
                stack => [
                    {cb => T(), args => ['arg1', 'arg2']},
                ]
            };

            is($state->{local}, $local_check, "Got accurate state");

            subtest nested_transaction => sub {
                $one->transaction(
                    'r' => sub {
                        my ($also_the_one, $also_state) = @_;

                        ref_is($also_the_one, $one,   "got the same instance");
                        ref_is($also_state,   $state, "Got the same state object");

                        is(
                            $state->{local},
                            {
                                lock  => T(),
                                write => F(),
                                mode  => 'r',
                                stack => [
                                    {cb => T(), args => ['arg1', 'arg2']},
                                    {cb => T(), args => []},
                                ]
                            },
                            "State temporarily modified"
                        );
                    },
                );
            };

            is($one->transaction(), $state, "transaction with no callback returns state");

            is($state->{local}, $local_check, "State restored");

            is($state->{runners}, {}, "Runner not added yet");

            return $state;
        },
        'arg1',
        'arg2'
    );

    like(
        $end_state,
        {
            ords    => {runners => 2},       # Incremented count for this runner
            local   => {lock    => FDNE},    # Lock released
            runners => {
                one => {                     # Added runner
                    ord       => 1,
                    user      => $ENV{USER},
                    seen      => T(),
                    runner_id => 'one',
                },
            },
        },
        "Got correct end state"
    );

    my $two   = inst(runner_id => 'two', state_file => $one->{state_file});
    my $state = $two->update_registration;

    ok($state->{runners}->{two}, "Got registration");

    $two->transaction(
        rw => sub {
            my ($me, $state) = @_;
            $state->{runners}->{two}->{remove} = 1;
        }
    );

    $state = $one->transaction(
        ro => sub {
            my ($me, $state) = @_;
            ok(!$state->{runners}->{two}, "Two is not registered anymore");
        }
    );

    like(
        dies { $two->transaction('rw') },
        qr/Shared slot registration expired/,
        "Cannot proceed if our registration expired",
    );

    my $three = inst(runner_id => 'three', state_file => $one->{state_file});
    $state = $three->update_registration;

    ok($state->{runners}->{three}, "Got registration");

    $one->transaction(
        rw => sub {
            my ($me, $state) = @_;
            $state->{runners}->{three}->{seen} = 1;    # Very long time ago.
        }
    );

    # Make sure RO mode is aware, even though it does not write the update
    $state = $one->transaction(
        ro => sub {
            my ($me, $state) = @_;
            ok(!$state->{runners}->{three}, "Three is not registered anymore (timed out)");
            ok(!$state->{runners}->{two},   "Two is not registered anymore");
        }
    );

    my $called_advance = 0;
    my $c              = mock $CLASS => (
        override => {
            _advance => sub { $called_advance++ },
        }
    );

    $state = $one->transaction(
        rw => sub {
            my ($me, $state) = @_;
            ok(!$state->{runners}->{three}, "Three is not registered anymore (timed out)");
            ok(!$state->{runners}->{two},   "Two is not registered anymore");
            return $state;
        }
    );

    is($called_advance, 1, "advance was called");

    delete $state->{local};

    my $stored = Test2::Harness::Util::File::JSON->new(name => $one->state_file)->read;
    is($state, $stored, "state and stored match");
};

sub consistent_state {
    my ($insts, $status_check) = @_;

    my $ctx = context();

    my $state;
    subtest "consistent state" => sub {
        my $base   = $state = shift(@$insts);
        my $status = $base->status;

        my $idx = 1;
        while (my $i = shift @$insts) {
            my $st2 = $i->status;
            is($st2, $status, "state [" . $idx++ . "] matches status [0]");
        }

        use Data::Dumper;
        is($status, $status_check, "State matches expectations", Dumper($status)) if $status_check;
    };

    $ctx->release;

    return $state;
}

subtest slots => sub {
    my $one   = inst(runner_id => 'one');
    my $two   = inst(runner_id => 'two',   state_file => $one->{state_file});
    my $three = inst(runner_id => 'three', state_file => $one->{state_file});

    like(
        $one->request_slots(job_id => "job_1", count => 1),
        T,
        "Got slot assignment right away",
    );
    consistent_state(
        [$one, $two, $three],
        hash {
            field state => hash {
                field pending  => [];
                field assigned => {};
                field queue    => {
                    one => {job_1 => hash { field count => 1; field job_id => 'job_1'; field stage => 'queue'; etc }},
                };
                etc;
            };
            field used_count      => 1;
            field available_count => 9;
            field request_count   => 0;
            field release_count   => 0;
            field pending         => {};
            field used            => {one => 1, two => FDNE, three => FDNE};
        },
    );

    ok($one->get_ready_request('job_1'), "Got job request");
    consistent_state(
        [$one, $two, $three],
        hash {
            field state => hash {
                field pending  => [];
                field queue    => {};
                field assigned => {
                    one => {job_1 => hash { field count => 1; field job_id => 'job_1'; field stage => 'assigned'; etc }},
                };
                etc;
            };
            field used_count      => 1;
            field available_count => 9;
            field request_count   => 0;
            field release_count   => 0;
            field pending         => {};
            field used            => {one => 1, two => FDNE, three => FDNE};
        },
    );

    like(
        $two->request_slots(job_id => "job_1", count => 1),
        T,
        "Got slot assignment right away",
    );
    ok($two->get_ready_request('job_1'), "Got job request");
    consistent_state(
        [$one, $two, $three],
        hash {
            field state => hash {
                field pending  => [];
                field queue    => {};
                field assigned => {
                    one => {job_1 => hash { field count => 1; etc }},
                    two => {job_1 => hash { field count => 1; etc }},
                };

                etc;
            };
            field used_count      => 2;
            field available_count => 8;
            field request_count   => 0;
            field release_count   => 0;
            field pending         => {};
            field used            => {one => 1, two => 1, three => FDNE};
        },
    );

    like(
        $three->request_slots(job_id => "job_1", count => 1),
        T,
        "Got slot assignment right away",
    );
    ok($three->get_ready_request('job_1'), "Got job request");
    consistent_state(
        [$one, $two, $three],
        hash {
            field state => hash {
                field pending  => [];
                field queue    => {};
                field assigned => {
                    one   => {job_1 => hash { field count => 1; etc }},
                    two   => {job_1 => hash { field count => 1; etc }},
                    three => {job_1 => hash { field count => 1; etc }},
                };

                etc;
            };
            field used_count      => 3;
            field available_count => 7;
            field request_count   => 0;
            field release_count   => 0;
            field pending         => {};
            field used            => {one => 1, two => 1, three => 1};
        },
    );

    like(
        $one->request_slots(job_id => "job_2", count => 3),
        T,
        "Got slot assignment right away",
    );
    ok($one->get_ready_request('job_2'), "Got job request");
    consistent_state(
        [$one, $two, $three],
        hash {
            field state => hash {
                field pending  => [];
                field queue    => {};
                field assigned => {
                    one => {
                        job_1 => hash { field count => 1; etc },
                        job_2 => hash { field count => 3; etc },
                    },
                    two   => {job_1 => hash { field count => 1; etc }},
                    three => {job_1 => hash { field count => 1; etc }},
                };
                etc;
            };
            field used_count      => 6;
            field available_count => 4;
            field request_count   => 0;
            field release_count   => 0;
            field pending         => {};
            field used            => {one => 4, two => 1, three => 1};
        },
    );

    like(
        $two->request_slots(job_id => "job_2", count => 3),
        T,
        "Got slot assignment right away",
    );
    ok($two->get_ready_request('job_2'), "Got job request");
    consistent_state(
        [$one, $two, $three],
        hash {
            field state => hash {
                field pending  => [];
                field queue    => {};
                field assigned => {
                    one => {
                        job_1 => hash { field count => 1; etc },
                        job_2 => hash { field count => 3; etc },
                    },
                    two => {
                        job_1 => hash { field count => 1; etc },
                        job_2 => hash { field count => 3; etc },
                    },
                    three => {job_1 => hash { field count => 1; etc }},
                };
                etc;
            };
            field used_count      => 9;
            field available_count => 1;
            field request_count   => 0;
            field release_count   => 0;
            field pending         => {};
            field used            => {one => 4, two => 4, three => 1};
        },
    );

    like(
        $three->request_slots(job_id => "job_2", count => 3),
        F,
        "Unable to get slot",
    );
    ok(!$three->get_ready_request('job_2'), "Got job request");
    consistent_state(
        [$one, $two, $three],
        hash {
            field state => hash {
                field pending  => [hash { field runner_id => 'three'; field count => 3; field job_id => 'job_2'; etc }];
                field queue    => {};
                field assigned => {
                    one => {
                        job_1 => hash { field count => 1; etc },
                        job_2 => hash { field count => 3; etc },
                    },
                    two => {
                        job_1 => hash { field count => 1; etc },
                        job_2 => hash { field count => 3; etc },
                    },
                    three => {job_1 => hash { field count => 1; etc }},
                };
                etc;
            };
            field used_count      => 9;
            field available_count => 1;
            field request_count   => 3;
            field release_count   => 0;
            field pending         => {three => 3};
            field used            => {one   => 4, two => 4, three => 1};
        },
    );

    like(
        $three->request_slots(job_id => "job_2", count => 1),
        T,
        "Got slot after count reduction",
    );
    ok($three->get_ready_request('job_2'), "Got job request");
    consistent_state(
        [$one, $two, $three],
        hash {
            field state => hash {
                field pending  => [];
                field queue    => {};
                field assigned => {
                    one => {
                        job_1 => hash { field count => 1; etc },
                        job_2 => hash { field count => 3; etc },
                    },
                    two => {
                        job_1 => hash { field count => 1; etc },
                        job_2 => hash { field count => 3; etc },
                    },
                    three => {
                        job_1 => hash { field count => 1; etc },
                        job_2 => hash { field count => 1; etc },
                    },
                };
                etc;
            };
            field used_count      => 10;
            field available_count => 0;
            field request_count   => 0;
            field release_count   => 0;
            field pending         => {};
            field used            => {one => 4, two => 4, three => 2};
        },
    );

    # Order matters, we want 2 to come before 1
    ok(!$two->request_slots(job_id => 'job_3', count => 3), "Request 3, not ready");
    ok(!$one->request_slots(job_id => 'job_3', count => 3), "Request 3, not ready");
    ok(!$three->request_slots(job_id => 'job_3', count => 3), "Request 3, not ready");
    consistent_state(
        [$one, $two, $three],
        hash {
            field state => hash {
                field pending => [
                    hash { field runner_id => 'two';   field count => 3; field job_id => 'job_3'; etc },
                    hash { field runner_id => 'one';   field count => 3; field job_id => 'job_3'; etc },
                    hash { field runner_id => 'three'; field count => 3; field job_id => 'job_3'; etc },
                ];
                field queue    => {};
                field assigned => {
                    one => {
                        job_1 => hash { field count => 1; etc },
                        job_2 => hash { field count => 3; etc },
                    },
                    two => {
                        job_1 => hash { field count => 1; etc },
                        job_2 => hash { field count => 3; etc },
                    },
                    three => {
                        job_1 => hash { field count => 1; etc },
                        job_2 => hash { field count => 1; etc },
                    },
                };
                etc;
            };
            field used_count      => 10;
            field available_count => 0;
            field request_count   => 9;
            field release_count   => 0;
            field pending         => {one => 3, two => 3, three => 3};
            field used            => {one => 4, two => 4, three => 2};
        },
    );

    $one->release_slots('job_1');
    $two->release_slots('job_1');
    $three->release_slots('job_1');
    ok($three->get_ready_request('job_3'), "Got job request");
    consistent_state(
        [$one, $two, $three],
        hash {
            field state => hash {
                field pending => [
                    hash { field runner_id => 'two'; field count => 3; field job_id => 'job_3'; etc },
                    hash { field runner_id => 'one'; field count => 3; field job_id => 'job_3'; etc },
                ];
                field queue    => {};
                field assigned => {
                    one => {
                        job_2 => hash { field count => 3; etc },
                    },
                    two => {
                        job_2 => hash { field count => 3; etc },
                    },
                    three => {
                        job_2 => hash { field count => 1; etc },
                        job_3 => hash { field count => 3; etc },
                    },
                };
                etc;
            };
            field used_count      => 10;
            field available_count => 0;
            field request_count   => 6;
            field release_count   => 0;
            field pending         => {one => 3, two => 3};
            field used            => {one => 3, two => 3, three => 4};
        },
    );

    $three->release_slots('job_3');
    consistent_state(
        [$one, $two, $three],
        hash {
            field state => hash {
                field pending => [
                    hash { field runner_id => 'two'; field count => 3; field job_id => 'job_3'; etc },
                ];
                field queue => {
                    one => {
                        job_3 => hash { field runner_id => 'one'; field count => 3; field job_id => 'job_3'; etc },
                    },
                };
                field assigned => {
                    one => {
                        job_2 => hash { field count => 3; etc },
                    },
                    two => {
                        job_2 => hash { field count => 3; etc },
                    },
                    three => {
                        job_2 => hash { field count => 1; etc },
                    },
                };
                etc;
            };
            field used_count      => 10;
            field available_count => 0;
            field request_count   => 3;
            field release_count   => 0;
            field pending         => {two => 3};
            field used            => {one => 6, two => 3, three => 1};
        },
    );

    is([$one->ready_request_list], ['job_3'], "Got ready jobs");
    is(
        $one->get_ready_request('job_3'),
        hash { field runner_id => 'one'; field count => 3; field job_id => 'job_3'; etc },
        "Got the ready slot request",
    );

    is(
        $one->get_ready_request('job_3'),
        undef,
        "Can only get valid ones, and only once",
    );

    consistent_state(
        [$one, $two, $three],
        hash {
            field state => hash {
                field pending => [
                    hash { field runner_id => 'two'; field count => 3; field job_id => 'job_3'; etc },
                ];
                field queue    => {};
                field assigned => {
                    one => {
                        job_2 => hash { field count => 3; etc },
                        job_3 => hash { field count => 3; etc },
                    },
                    two => {
                        job_2 => hash { field count => 3; etc },
                    },
                    three => {
                        job_2 => hash { field count => 1; etc },
                    },
                };
                etc;
            };
            field used_count      => 10;
            field available_count => 0;
            field request_count   => 3;
            field release_count   => 0;
            field pending         => {two => 3};
            field used            => {one => 6, two => 3, three => 1};
        },
    );

    # Make sure removing a reg causes the slots to be free
    $one->remove_registration;
    consistent_state(
        [$two, $three],
        hash {
            field state => hash {
                field pending => [];
                field queue   => {
                    two => {
                        job_3 => hash { field runner_id => 'two'; field count => 3; field job_id => 'job_3'; etc },
                    },
                };
                field assigned => {
                    two => {
                        job_2 => hash { field count => 3; etc },
                    },
                    three => {
                        job_2 => hash { field count => 1; etc },
                    },
                };
                field runners => {
                    one   => DNE(),    # Make sure this is gone.
                    two   => T(),
                    three => T(),
                };
                etc;
            };
            field used_count      => 7;
            field available_count => 3;
            field request_count   => 0;
            field release_count   => 0;
            field pending         => {};
            field used            => {one => DNE, two => 6, three => 1};
        },
    );
};

subtest registration => sub {
    my $one   = inst(runner_id => 'one');
    my $two   = inst(runner_id => 'two',   state_file => $one->{state_file});
    my $three = inst(runner_id => 'three', state_file => $one->{state_file});

    $one->update_registration;
    consistent_state(
        [$one, $two, $three],
        hash {
            field state => hash {
                field runners => {
                    one => T(),
                };
                etc;
            };
            etc;
        },
    );

    $two->update_registration;
    consistent_state(
        [$one, $two, $three],
        hash {
            field state => hash {
                field runners => {
                    one => T(),
                    two => T(),
                };
                etc;
            };
            etc;
        },
    );

    $three->update_registration;
    consistent_state(
        [$one, $two, $three],
        hash {
            field state => hash {
                field runners => {
                    one   => T(),
                    two   => T(),
                    three => T(),
                };
                etc;
            };
            etc;
        },
    );

    $two->remove_registration;
    consistent_state(
        [$one, $two, $three],
        hash {
            field state => hash {
                field runners => {
                    one   => T(),
                    two   => DNE(),
                    three => T(),
                };
                etc;
            };
            etc;
        },
    );

    # Emulate 'three' timing out.
    my $file = Test2::Harness::Util::File::JSON->new(name => $one->{state_file});
    my $data = $file->read;
    $data->{runners}->{three}->{seen} -= 100 + $one->TIMEOUT;
    $file->write($data);

    consistent_state(
        [$one, $two, $three],
        hash {
            field state => hash {
                field runners => {
                    one   => T(),
                    two   => DNE(),
                    three => DNE(),
                };
                etc;
            };
            etc;
        },
    );

    like(
        dies { $three->update_registration },
        qr/Shared slot registration expired/,
        "Cannot write after timing out"
    );
};

subtest _entry_expired => sub {
    my $one = inst(runner_id => 'one');

    ok($one->_entry_expired(undef),         "Invalid entry is expired");
    ok($one->_entry_expired({remove => 1}), "Entry to be removed is expired");
    ok($one->_entry_expired({}),            "no 'seen' field expired");

    ok(!$one->_entry_expired({seen => time}), "Recently seen, not expired");

    ok($one->_entry_expired({seen => (time - (10 + $one->TIMEOUT))}), "Old is expired");
};

subtest sorting => sub {
    my $one   = inst(runner_id => 'one');
    my $two   = inst(runner_id => 'two',   state_file => $one->{state_file});
    my $three = inst(runner_id => 'three', state_file => $one->{state_file});

    my @list = sort { $one->_our_request_first({}, $a, $b) } (
        {ord => 1, runner_id => 101},
        {ord => 2, runner_id => 102},
        {ord => 3, runner_id => 'one'},
        {ord => 4, runner_id => 103},
        {ord => 5, runner_id => 104},
    );
    is(
        \@list,
        [
            {ord => 3, runner_id => 'one'},
            {ord => 1, runner_id => 101},
            {ord => 2, runner_id => 102},
            {ord => 4, runner_id => 103},
            {ord => 5, runner_id => 104},
        ],
        "Our item moved up"
    );

    @list = sort { $one->_request_sort_by_used_slots({local => {used => {one => 4, two => 2, three => 6}}}, $a, $b) } (
        {ord => 1, runner_id => 'one'},
        {ord => 2, runner_id => 'two'},
        {ord => 3, runner_id => 'three'},
        {ord => 4, runner_id => 'three'},
        {ord => 5, runner_id => 'two'},
        {ord => 6, runner_id => 'one'},
    );
    is(
        \@list,
        [
            {ord => 2, runner_id => 'two'},
            {ord => 5, runner_id => 'two'},
            {ord => 1, runner_id => 'one'},
            {ord => 6, runner_id => 'one'},
            {ord => 3, runner_id => 'three'},
            {ord => 4, runner_id => 'three'},
        ],
        "Runs with least slots come first"
    );

    $one->update_registration;
    $three->update_registration;
    $two->update_registration;

    @list = sort { $one->_request_sort_by_run_order($one->state, $a, $b) } (
        {ord => 1, runner_id => 'one'},
        {ord => 2, runner_id => 'two'},
        {ord => 3, runner_id => 'three'},
        {ord => 4, runner_id => 'three'},
        {ord => 5, runner_id => 'two'},
        {ord => 6, runner_id => 'one'},
    );
    is(
        \@list,
        [
            {ord => 1, runner_id => 'one'},
            {ord => 6, runner_id => 'one'},
            {ord => 3, runner_id => 'three'},
            {ord => 4, runner_id => 'three'},
            {ord => 2, runner_id => 'two'},
            {ord => 5, runner_id => 'two'},
        ],
        "Older runs first"
    );

    @list = sort { $one->_request_sort_by_request_order({}, $a, $b) } (
        {ord => 6, runner_id => 'one'},
        {ord => 4, runner_id => 'three'},
        {ord => 5, runner_id => 'two'},
        {ord => 3, runner_id => 'three'},
        {ord => 1, runner_id => 'one'},
        {ord => 2, runner_id => 'two'},
    );
    is(
        \@list,
        [
            {ord => 1, runner_id => 'one'},
            {ord => 2, runner_id => 'two'},
            {ord => 3, runner_id => 'three'},
            {ord => 4, runner_id => 'three'},
            {ord => 5, runner_id => 'two'},
            {ord => 6, runner_id => 'one'},
        ],
        "Older requests first"
    );
};

done_testing;
