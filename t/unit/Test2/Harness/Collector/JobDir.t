use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempdir/;
use Test2::Harness::Collector::JobDir;

subtest '_poll_timeouts uses correct buffer for each timeout type' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $jdir = Test2::Harness::Collector::JobDir->new(
        run_id   => 'run-1',
        job_id   => 'job-1',
        job_root => $dir,
    );

    my $et_stamp  = '1000000.1234';
    my $et_delta  = '30.0000';
    my $pet_stamp = '2000000.5678';
    my $pet_delta = '15.0000';

    # Simulate both timeout buffers being filled with distinct values
    $jdir->{et_buffer}  = "$et_stamp $et_delta";
    $jdir->{pet_buffer} = "$pet_stamp $pet_delta";

    my @events = $jdir->_poll_timeouts();
    is(scalar @events, 2, 'got two timeout events');

    # First event should be the event timeout, using ET_BUFFER data
    my $et_event = $events[0];
    like($et_event->{facet_data}{about}{details}, qr/event/, 'first event is event timeout');
    is($et_event->{stamp}, $et_stamp, 'event timeout uses ET_BUFFER stamp');

    # Second event should be the post-exit timeout, using PET_BUFFER data
    my $pet_event = $events[1];
    like($pet_event->{facet_data}{about}{details}, qr/post-exit/, 'second event is post-exit timeout');
    is($pet_event->{stamp}, $pet_stamp, 'post-exit timeout uses PET_BUFFER stamp (not ET_BUFFER)');

    # Verify they are actually different (the bug would make them the same)
    isnt($et_event->{stamp}, $pet_event->{stamp}, 'timeout events have different stamps from their respective buffers');
};

subtest '_poll_timeouts only fires once per type' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $jdir = Test2::Harness::Collector::JobDir->new(
        run_id   => 'run-2',
        job_id   => 'job-2',
        job_root => $dir,
    );

    $jdir->{et_buffer}  = "1000000.0 5.0";
    $jdir->{pet_buffer} = "2000000.0 10.0";

    my @first  = $jdir->_poll_timeouts();
    my @second = $jdir->_poll_timeouts();

    is(scalar @first, 2, 'first call returns both timeout events');
    is(scalar @second, 0, 'second call returns nothing (done flags set)');
};

done_testing;
