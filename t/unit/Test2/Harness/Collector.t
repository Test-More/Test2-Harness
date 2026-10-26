use Test2::V0 -target => 'Test2::Harness::Collector';
use File::Spec;
use File::Temp qw/tempdir/;
use Time::HiRes qw/time/;
use MIME::Base64 qw/decode_base64/;

use Test2::Harness::Run;

my $tmp    = tempdir(CLEANUP => 1);
my $run_id = 'test-run';
mkdir(File::Spec->catdir($tmp, $run_id)) or die "Could not create run dir: $!";

sub new_collector {
    return $CLASS->new(
        run     => Test2::Harness::Run->new(run_id => $run_id),
        workdir => $tmp,
        run_id  => $run_id,
        action  => sub { },
        @_,
    );
}

subtest defaults => sub {
    my $one = new_collector();

    is($one->wait_time, 0.02,             "wait_time defaults to 0.02");
    is($one->idle_wait, $CLASS->MIN_WAIT, "backoff starts at the floor");
};

subtest wait_time_is_settable => sub {
    my $one = new_collector(wait_time => 0.5);

    is($one->wait_time, 0.5, "wait_time can be set by the constructor");
};

subtest backoff_doubles_and_caps => sub {
    my $one = new_collector(wait_time => 0.008);

    my @seen;
    for (1 .. 5) {
        push @seen => $one->idle_wait;
        $one->idle_sleep;
    }

    is(
        \@seen,
        [0.001, 0.002, 0.004, 0.008, 0.008],
        "each sleep doubles the wait until it reaches the wait_time ceiling, then holds"
    );

    is($one->idle_wait, 0.008, "wait stays at the ceiling");
};

subtest reset_returns_to_the_floor => sub {
    my $one = new_collector(wait_time => 0.008);

    $one->idle_sleep for 1 .. 4;
    is($one->idle_wait, 0.008, "backed off to the ceiling");

    $one->reset_idle_wait;
    is($one->idle_wait, $CLASS->MIN_WAIT, "reset returns to the floor");
};

subtest ceiling_below_the_floor_is_honored => sub {
    my $one = new_collector(wait_time => 0.0005);

    $one->idle_sleep;
    is($one->idle_wait, 0.0005, "a wait_time under the floor caps the very first backoff");
};

subtest idle_sleep_actually_sleeps => sub {
    my $one = new_collector();

    my $start = time;
    $one->idle_sleep;
    my $slept = time - $start;

    # Deliberately loose: this asserts that a sleep happens at all, not how
    # precisely the scheduler honors the requested duration.
    ok($slept >= 0.0005, "idle_sleep waited", "slept ${slept}s");
};

subtest aux_attachments => sub {
    my @events;
    my $one = new_collector(show_runner_output => 1, action => sub { push @events => $_[0] });
    @events = ();    # Drop the harness_run event the constructor sends.

    my $dir = File::Spec->catdir($tmp, 'aux_logs', 'attachments');
    mkdir(File::Spec->catdir($tmp, 'aux_logs')) or die "Could not create aux_logs: $!";
    mkdir($dir)                                 or die "Could not create attachments dir: $!";

    my $bytes = join '' => map { chr } 0 .. 255;
    for my $file (['bundle.tar.gz', $bytes], ['.shot.png.tmp', 'partial']) {
        open(my $fh, '>:raw', File::Spec->catfile($dir, $file->[0])) or die "Could not write $file->[0]: $!";
        print $fh $file->[1];
        close($fh) or die "Could not close $file->[0]: $!";
    }

    is($one->process_runner_output, 1, "one event, the dotfile is ignored");
    is(
        $events[0]->facet_data,
        hash {
            field harness => T();
            field info    => [{tag => 'ARTIFACT', details => 'attached bundle.tar.gz', important => 1}];
            field binary  => [{filename => 'bundle.tar.gz', details => 'bundle.tar.gz', data => T(), is_image => 0}];
            etc;
        },
        "attachment event has the info and binary facets"
    );
    is($events[0]->job_id,                                           0,      "attached to the harness job");
    is(decode_base64($events[0]->facet_data->{binary}->[0]->{data}), $bytes, "data decodes to the original bytes, not decompressed");

    @events = ();
    is($one->process_runner_output, 0, "nothing is attached twice");

    rename(File::Spec->catfile($dir, '.shot.png.tmp'), File::Spec->catfile($dir, 'shot.png')) or die "Could not rename: $!";
    is($one->process_runner_output,                       1,          "the renamed file is attached on the next poll");
    is($events[0]->facet_data->{binary}->[0]->{filename}, 'shot.png', "under its final name");
    is($events[0]->facet_data->{binary}->[0]->{is_image}, 1,          "image extension sets is_image");
};

done_testing;
