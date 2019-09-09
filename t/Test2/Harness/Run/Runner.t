use Test2::V0 -target => 'Test2::Harness::Run::Runner';
# HARNESS-DURATION-SHORT
skip_all "Not done, come back!";

use File::Temp qw/tempdir/;
use Test2::Harness::Run;

subtest queuing => sub {
    my $dir = tempdir(CLEANUP => 1, TMP => 1);

    subtest finite_1 => sub {
        my $run = Test2::Harness::Run->new(
            run_id => 1,

            finite    => 1,
            job_count => 1,
            libs      => [],

            env_vars    => {},
            use_stream  => 1,
            use_fork    => 1,
            use_timeout => 1,
            times       => 1,
        );

        my $one = $CLASS->new(dir => $dir, run => $run);

        is($one->_next, 'next_by_stamp', "Set to next by stamp");
    };

    subtest finite_5 => sub {
        my $run = Test2::Harness::Run->new(
            run_id => 1,

            finite    => 1,
            job_count => 5,
            libs      => [],

            env_vars    => {},
            use_stream  => 1,
            use_fork    => 1,
            use_timeout => 1,
            times       => 1,
        );

        my $one = $CLASS->new(dir => $dir, run => $run);

        is($one->_next, 'next_finite', "Set to next finite");
    };

    subtest infinite_1 => sub {
        my $run = Test2::Harness::Run->new(
            run_id => 1,

            finite    => 0,
            job_count => 1,
            libs      => [],

            env_vars    => {},
            use_stream  => 1,
            use_fork    => 1,
            use_timeout => 1,
            times       => 1,
        );

        my $one = $CLASS->new(dir => $dir, run => $run);

        is($one->_next, 'next_by_stamp', "Set to next by stamp");
    };

    subtest infinite_5 => sub {
        my $run = Test2::Harness::Run->new(
            run_id => 1,

            finite    => 0,
            job_count => 5,
            libs      => [],

            env_vars    => {},
            use_stream  => 1,
            use_fork    => 1,
            use_timeout => 1,
            times       => 1,
        );

        my $one = $CLASS->new(dir => $dir, run => $run);

        is($one->_next, 'next_fair', "Set to next fair");
    };

    subtest running => sub {
        my $run = Test2::Harness::Run->new(
            run_id => 1,

            finite    => 1,
            job_count => 1,
            libs      => [],

            env_vars    => {},
            use_stream  => 1,
            use_fork    => 1,
            use_timeout => 1,
            times       => 1,
        );

        my $one = $CLASS->new(dir => $dir, run => $run);
        $one->init_state;

        is($one->running, 0, "None running");

        $one->state->{running}->{general}->{1} = 'exit_file';
        is($one->running, 1, "1 running");

        $one->state->{running}->{long}->{2}      = 'exit_file';
        $one->state->{running}->{long}->{3}      = 'exit_file';
        $one->state->{running}->{medium}->{4}    = 'exit_file';
        $one->state->{running}->{isolation}->{5} = 'exit_file';

        is($one->running, 5, "5 running");

        delete $one->state->{running}->{general}->{1};
        delete $one->state->{running}->{isolation}->{5};

        is($one->running, 3, "3 running");
    };

    subtest pending => sub {
        my $run = Test2::Harness::Run->new(
            run_id => 1,

            finite    => 1,
            job_count => 1,
            libs      => [],

            env_vars    => {},
            use_stream  => 1,
            use_fork    => 1,
            use_timeout => 1,
            times       => 1,
        );

        my $one = $CLASS->new(dir => $dir, run => $run);
        $one->init_state;

        is($one->pending, 0, "0 pending jobs");

        push @{$one->state->{pending}->{general}}   => {stamp => 1};
        push @{$one->state->{pending}->{medium}}    => {stamp => 2};
        push @{$one->state->{pending}->{long}}      => {stamp => 3};
        push @{$one->state->{pending}->{isolation}} => {stamp => 4};
        push @{$one->state->{pending}->{long}}      => {stamp => 5};

        is($one->pending, 5, "5 pending jobs");
    };

    subtest _cats_by_stamp => sub {
        my $run = Test2::Harness::Run->new(
            run_id => 1,

            finite    => 1,
            job_count => 1,
            libs      => [],

            env_vars    => {},
            use_stream  => 1,
            use_fork    => 1,
            use_timeout => 1,
            times       => 1,
        );

        my $one = $CLASS->new(dir => $dir, run => $run);
        $one->init_state;

        push @{$one->state->{pending}->{general}}   => {stamp => 1};
        push @{$one->state->{pending}->{medium}}    => {stamp => 2};
        push @{$one->state->{pending}->{long}}      => {stamp => 3};
        push @{$one->state->{pending}->{isolation}} => {stamp => 4};
        push @{$one->state->{pending}->{long}}      => {stamp => 5};

        is([$one->_cats_by_stamp], ['general', 'medium', 'long', 'isolation'], "sorted pending jobs");

        shift @{$one->state->{pending}->{long}};
        is([$one->_cats_by_stamp], ['general', 'medium', 'isolation', 'long'], "sorted pending jobs");
    };

    subtest next_by_stamp => sub {
        my $run = Test2::Harness::Run->new(
            run_id => 1,

            finite    => 1,
            job_count => 1,
            libs      => [],

            env_vars    => {},
            use_stream  => 1,
            use_fork    => 1,
            use_timeout => 1,
            times       => 1,
        );

        my $one = $CLASS->new(dir => $dir, run => $run);
        $one->init_state;

        push @{$one->state->{pending}->{general}}   => {stamp => 1};
        push @{$one->state->{pending}->{medium}}    => {stamp => 2};
        push @{$one->state->{pending}->{long}}      => {stamp => 3};
        push @{$one->state->{pending}->{isolation}} => {stamp => 4};
        push @{$one->state->{pending}->{long}}      => {stamp => 5};
        push @{$one->state->{pending}->{general}}   => {stamp => 6};

        is($one->next_by_stamp, {stamp => 1}, "Got expected item");
        is($one->next_by_stamp, {stamp => 2}, "Got expected item");
        is($one->next_by_stamp, {stamp => 3}, "Got expected item");
        is($one->next_by_stamp, {stamp => 4}, "Got expected item");

        $one->state->{running}->{isolation}->{4} = 1;
        is([$one->next_by_stamp(1,3)], [], "ISO is running, so we cannot do anything");
        delete $one->state->{running}->{isolation}->{4};

        is($one->next_by_stamp, {stamp => 5}, "Got expected item");
        is($one->next_by_stamp, {stamp => 6}, "Got expected item");
        is([$one->next_by_stamp], [], "Got empty list");
    };

    subtest next_finite => sub {
        my $run = Test2::Harness::Run->new(
            run_id => 1,

            finite    => 1,
            job_count => 3,
            libs      => [],

            env_vars    => {},
            use_stream  => 1,
            use_fork    => 1,
            use_timeout => 1,
            times       => 1,
        );

        my $one = $CLASS->new(dir => $dir, run => $run);
        $one->init_state;

        push @{$one->state->{pending}->{general}}   => {stamp => 1};
        push @{$one->state->{pending}->{medium}}    => {stamp => 2};
        push @{$one->state->{pending}->{long}}      => {stamp => 3};
        push @{$one->state->{pending}->{isolation}} => {stamp => 4};
        push @{$one->state->{pending}->{long}}      => {stamp => 5};
        push @{$one->state->{pending}->{general}}   => {stamp => 6};
        push @{$one->state->{pending}->{long}}      => {stamp => 7};
        push @{$one->state->{pending}->{general}}   => {stamp => 8};
        push @{$one->state->{pending}->{general}}   => {stamp => 9};
        push @{$one->state->{pending}->{general}}   => {stamp => 10};
        push @{$one->state->{pending}->{general}}   => {stamp => 11};

        is($one->next_finite(0, 3), {stamp => 3},  "Got the long item first, we have capacity");
        is($one->next_finite(1, 3), {stamp => 5},  "Got a long item again, we still have capacity");
        is($one->next_finite(2, 3), {stamp => 1},  "Got general for last slot");
        is($one->next_finite(2, 3), {stamp => 6},  "Got general again for last slot");
        is($one->next_finite(1, 3), {stamp => 7},  "Got another long since slots are free");
        is($one->next_finite(2, 3), {stamp => 8},  "Got general again for last slot");

        $one->state->{running}->{isolation}->{x} = 1;
        is([$one->next_finite(1,3)], [], "ISO is running, so we cannot do anything");
        delete $one->state->{running}->{isolation}->{x};

        is($one->next_finite(1, 3), {stamp => 2},  "Got medium due to free slots");
        is($one->next_finite(2, 3), {stamp => 9},  "Got general again for last slot");
        is($one->next_finite(1, 3), {stamp => 10}, "Got general again when between general and isolation");
        is($one->next_finite(2, 3), {stamp => 11}, "Got general again when between general and isolation");

        push @{$one->state->{pending}->{long}} => {stamp => 12};
        is($one->next_finite(2, 3), {stamp => 12}, "Will fill last slot with long if no generals");

        push @{$one->state->{pending}->{medium}} => {stamp => 13};
        is($one->next_finite(2, 3), {stamp => 13}, "Will fill last slot with medium if no generals");

        is([$one->next_finite(3, 3)], [], "Do not fill with iso while slots in use (3)");
        is([$one->next_finite(2, 3)], [], "Do not fill with iso while slots in use (2)");
        is([$one->next_finite(1, 3)], [], "Do not fill with iso while slots in use (1)");

        is($one->next_finite(0, 3), {stamp => 4}, "Will use isolationwhen slots are all free");

        push @{$one->state->{pending}->{isolation}} => {stamp => 14};
        is([$one->next_finite(1, 3)], [], "Do not fill with iso while slots in use (1)");

        is($one->next_finite(0, 3), {stamp => 14}, "Will use isolation when slots are all free");
    };

    subtest next_fair => sub {
        my $run = Test2::Harness::Run->new(
            run_id => 1,

            finite    => 0,
            job_count => 3,
            libs      => [],

            env_vars    => {},
            use_stream  => 1,
            use_fork    => 1,
            use_timeout => 1,
            times       => 1,
        );

        my $one = $CLASS->new(dir => $dir, run => $run);
        $one->init_state;

        push @{$one->state->{pending}->{general}}   => {stamp => 1};
        push @{$one->state->{pending}->{medium}}    => {stamp => 2};
        push @{$one->state->{pending}->{long}}      => {stamp => 3};
        push @{$one->state->{pending}->{isolation}} => {stamp => 4};
        push @{$one->state->{pending}->{long}}      => {stamp => 5};
        push @{$one->state->{pending}->{general}}   => {stamp => 6};
        push @{$one->state->{pending}->{long}}      => {stamp => 7};
        push @{$one->state->{pending}->{long}}      => {stamp => 8};
        push @{$one->state->{pending}->{long}}      => {stamp => 9};
        push @{$one->state->{pending}->{general}}   => {stamp => 10};
        push @{$one->state->{pending}->{general}}   => {stamp => 11};
        push @{$one->state->{pending}->{general}}   => {stamp => 12};
        push @{$one->state->{pending}->{general}}   => {stamp => 13};

        is($one->next_fair(0, 3), {stamp => 1},  "General, by stamp");
        $one->state->{running}->{general}->{1} = 1;
        is($one->next_fair(1, 3), {stamp => 2},  "Medium, by stamp");
        $one->state->{running}->{medium}->{2} = 1;
        is($one->next_fair(2, 3), {stamp => 3},  "Long, by stamp");
        $one->state->{running}->{long}->{3} = 1;

        delete $one->state->{running}->{general}->{1};
        is($one->next_fair(2,3), {stamp => 6}, "next is iso, cannot run it yet, but we have a long running,s o lets add a general");

        delete $one->state->{running}->{long}->{3};
        is([$one->next_fair(1,3)], [], "next is iso, cannot run it yet");

        delete $one->state->{running}->{medium}->{2};
        is($one->next_fair(0,3), {stamp => 4}, "Got ISO");
        $one->state->{running}->{isolation}->{4} = 1;

        is([$one->next_fair(1,3)], [], "ISO is running, so we cannot do anything");

        delete $one->state->{running}->{isolation}->{4};

        $one->state->{running}->{long}->{a} = 1;
        $one->state->{running}->{long}->{b} = 1;
        is($one->next_fair(2,3), {stamp => 10}, "We have 2 long's running, go right to a general");

        delete $one->state->{running}->{long}->{b};
        $one->state->{running}->{medium}->{c} = 1;
        is($one->next_fair(2,3), {stamp => 11}, "We have a long and a medium running, go right to a general");

        is($one->next_fair(2,3), {stamp => 12}, "We have a long and a medium running, go right to a general");
        is($one->next_fair(2,3), {stamp => 13}, "We have a long and a medium running, go right to a general");

        is($one->next_fair(2,3), {stamp => 5}, "We only have long left, go for it.");
    };

    subtest next => sub {
        my @next;
        my $pending = 0;

        my $control = mock $CLASS => (
            add => [
                next_one => sub { shift @next },
            ],
            override => [
                pending => sub { $pending },
            ],
        );

        my $run = Test2::Harness::Run->new(
            run_id => 1,

            finite    => 0,
            job_count => 3,
            libs      => [],

            env_vars    => {},
            use_stream  => 1,
            use_fork    => 1,
            use_timeout => 1,
            times       => 1,
        );

        my $one = $CLASS->new(dir => $dir, run => $run);
        $one->init_state;

        $one->{_next} = 'next_one';

        $one->state->{ended} = 1;
        $pending = 0;
        ok(!$one->next, "nothing left to do");

        $one->state->{ended} = 0;
        push @next => (undef, undef, {foo => 1});
        my $next = $one->next;
        is($next, {foo => 1}, "got next");

        push @next => (undef, undef, {foo => 1});
        $one->{hup} = 1;
        is($one->next, -1, 'hup, we return -1');
    };
};

done_testing;

1;

