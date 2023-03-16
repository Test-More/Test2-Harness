use Test2::V0 -target => 'Test2::Harness::IPC::SharedState';
use File::Temp qw/tempfile/;
use Test2::Plugin::DieOnFail;

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
        no_cache          => 1,
        %params,
    );
}

subtest init_checks => sub {
    for my $field (qw/state_file/) {
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
    my $one   = inst(access_id => 'one');
    my $state = $one->transaction('w');
    like(
        $state,
        {
            access => {
                one => {access_id => 'one'},    # The access added for our transacton
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
            write     => T,                               # This was a write transaction
        },
        "Local data is as expected",
    );

    my $stored = Test2::Harness::Util::File::JSON->new(name => $one->state_file)->read;
    is($state, $stored, "state and stored match");
};

subtest transaction => sub {
    my $one = inst(access_id => 'one');

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

            return $state;
        },
        'arg1',
        'arg2'
    );

    like(
        $end_state,
        {
            local   => {lock => FDNE},    # Lock released
            access => {
                one => {                  # Added runner
                    user      => $ENV{USER},
                    seen      => T(),
                    added     => T(),
                    access_id => 'one',
                },
            },
        },
        "Got correct end state"
    );

    my $two   = inst(access_id => 'two', state_file => $one->{state_file});
    my $state = $two->update_registration;

    ok($state->{access}->{two}, "Got registration");

    $two->transaction(
        rw => sub {
            my ($me, $state) = @_;
            $state->{access}->{two}->{remove} = 1;
        }
    );

    $state = $one->transaction(
        ro => sub {
            my ($me, $state) = @_;
            ok(!$state->{access}->{two}, "Two is not registered anymore");
        }
    );

    like(
        dies { $two->transaction('rw') },
        qr/Shared state registration expired/,
        "Cannot proceed if our registration expired",
    );

    my $three = inst(access_id => 'three', state_file => $one->{state_file});
    $state = $three->update_registration;

    ok($state->{access}->{three}, "Got registration");

    $one->transaction(
        rw => sub {
            my ($me, $state) = @_;
            $state->{access}->{three}->{seen} = 1;    # Very long time ago.
        }
    );

    # Make sure RO mode is aware, even though it does not write the update
    $state = $one->transaction(
        ro => sub {
            my ($me, $state) = @_;
            ok(!$state->{access}->{three}, "Three is not registered anymore (timed out)");
            ok(!$state->{access}->{two},   "Two is not registered anymore");
        }
    );

    $state = $one->transaction(
        rw => sub {
            my ($me, $state) = @_;
            ok(!$state->{access}->{three}, "Three is not registered anymore (timed out)");
            ok(!$state->{access}->{two},   "Two is not registered anymore");
            return $state;
        }
    );

    delete $state->{local};

    my $stored = Test2::Harness::Util::File::JSON->new(name => $one->state_file)->read;
    is($state, $stored, "state and stored match");
};

sub consistent_state {
    my ($insts, $state_check) = @_;

    my $ctx = context();

    my $state;
    subtest "consistent state" => sub {
        my $base  = $state = shift(@$insts);
        my $state = $base->state;

        my $idx = 1;
        while (my $i = shift @$insts) {
            my $st2 = $i->state;
            is($st2, $state, "state [" . $idx++ . "] matches state [0]");
        }

        use Data::Dumper;
        is($state, $state_check, "State matches expectations", Dumper($state)) if $state_check;
    };

    $ctx->release;

    return $state;
}

subtest registration => sub {
    my $one   = inst(access_id => 'one');
    my $two   = inst(access_id => 'two',   state_file => $one->{state_file});
    my $three = inst(access_id => 'three', state_file => $one->{state_file});

    $one->update_registration;
    consistent_state(
        [$one, $two, $three],
        hash {
            field access => {
                one => T(),
            };
            etc;
        },
    );

    $two->update_registration;
    consistent_state(
        [$one, $two, $three],
        hash {
            field access => {
                one => T(),
                two => T(),
            };
            etc;
        },
    );

    $three->update_registration;
    consistent_state(
        [$one, $two, $three],
        hash {
            field access => {
                one   => T(),
                two   => T(),
                three => T(),
            };
            etc;
        },
    );

    $two->remove_registration;
    consistent_state(
        [$one, $two, $three],
        hash {
            field access => {
                one   => T(),
                two   => DNE(),
                three => T(),
            };
            etc;
        },
    );

    # Emulate 'three' timing out.
    my $file = Test2::Harness::Util::File::JSON->new(name => $one->{state_file});
    my $data = $file->read;
    $data->{access}->{three}->{seen} -= 100 + $one->timeout;
    $file->write($data);

    consistent_state(
        [$one, $two, $three],
        hash {
            field access => {
                one   => T(),
                two   => DNE(),
                three => DNE(),
            };
            etc;
        },
    );

    like(
        dies { $three->update_registration },
        qr/Shared state registration expired/,
        "Cannot write after timing out"
    );
};

subtest _entry_expired => sub {
    my $one = inst(access_id => 'one');

    ok($one->_entry_expired(undef),         "Invalid entry is expired");
    ok($one->_entry_expired({remove => 1}), "Entry to be removed is expired");
    ok($one->_entry_expired({}),            "no 'seen' field expired");

    ok(!$one->_entry_expired({seen => time}), "Recently seen, not expired");

    ok($one->_entry_expired({seen => (time - (10 + $one->timeout))}), "Old is expired");
};

done_testing;
