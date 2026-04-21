use Test2::V0;
use File::Path qw/make_path/;
use File::Temp qw/tempdir/;

use App::Yath2::ArtifactReader;

# Capture renderer: records every hook call in order.
package CaptureRenderer;
use Role::Tiny::With;
with 'App::Yath2::Role::Renderer';
sub new { bless {log => []}, shift }
sub events { $_[0]->{log} }

sub start_of_run {
    my $self = shift;
    push @{$self->{log}} => [start_of_run => {@_}];
}

sub event_in {
    my ($self, $ev) = @_;
    push @{$self->{log}} => [event_in => $ev];
}

sub end_of_run {
    my $self = shift;
    push @{$self->{log}} => [end_of_run => {@_}];
}

sub shutdown {
    my $self = shift;
    push @{$self->{log}} => ['shutdown'];
}

# Canned-response fake spawn: each call pops from the queue of
# run_status responses; list_run_artifacts returns the configured
# artifact map.
package FakeSpawn;
use Object::HashBase qw{
    +statuses
    <artifacts
    <calls
};

sub init {
    my $self = shift;
    $self->{calls} //= [];
}

sub run_status {
    my ($self, $rid) = @_;
    push @{$self->{calls}} => ['run_status', $rid];
    my $next = shift @{$self->{statuses}};
    return $next // {ok => 1, state => 'completed', run_id => $rid, pending => [], running => [], done => []};
}

sub list_run_artifacts {
    my ($self, $rid) = @_;
    push @{$self->{calls}} => ['list_run_artifacts', $rid];
    return $self->{artifacts} // {ok => 1, run_id => $rid, artifacts => {}};
}

sub get_run_status {
    my ($self, $rid) = @_;
    return $self->run_status($rid);
}

package main;

subtest 'quiet mode: only end-of-run summary reaches the renderer' => sub {
    my $r = CaptureRenderer->new;

    my $spawn = FakeSpawn->new(statuses => [
        {ok => 1, state => 'running',   pending => ['j1'], running => [],     done => []},
        {ok => 1, state => 'running',   pending => [],     running => ['j1'], done => []},
        {ok => 1, state => 'completed', pending => [],     running => [],     done => ['j1'], pass_count => 1, fail_count => 0},
    ]);

    my $ar = App::Yath2::ArtifactReader->new(
        spawn     => $spawn,
        run_id    => 'r-1',
        renderers => [$r],
        mode      => 'quiet',
        poll_interval => 0.001,
    );

    $ar->run;

    # In quiet mode we expect:
    #   start_of_run, <no per-job events>, one synthetic run_complete
    #   event_in, end_of_run, shutdown.
    my @kinds = map { $_->[0] } @{$r->events};
    is(
        \@kinds,
        [qw/start_of_run event_in end_of_run shutdown/],
        'quiet mode emits only synthetic run_complete',
    );

    # Verify the single event_in carries run_complete.
    my $ev = $r->events->[1][1];
    ok(exists $ev->{facet_data}{harness}{run_complete}, 'the one event is run_complete');
};

subtest 'default mode: per-job verdicts + run_complete' => sub {
    my $r = CaptureRenderer->new;

    my $spawn = FakeSpawn->new(statuses => [
        {ok => 1, state => 'running',   pending => ['j1'], running => [],     done => []},
        {ok => 1, state => 'running',   pending => [],     running => ['j1'], done => []},
        {ok => 1, state => 'completed', pending => [],     running => [],     done => ['j1'], pass_count => 1, fail_count => 0},
    ]);

    my $ar = App::Yath2::ArtifactReader->new(
        spawn     => $spawn,
        run_id    => 'r',
        renderers => [$r],
        poll_interval => 0.001,
    );

    $ar->run;

    my @event_kinds;
    for my $entry (@{$r->events}) {
        next unless $entry->[0] eq 'event_in';
        my $h = $entry->[1]{facet_data}{harness} // {};
        push @event_kinds => 'test_job_started'   if $h->{test_job_started};
        push @event_kinds => 'test_job_completed' if $h->{test_job_completed};
        push @event_kinds => 'run_complete'       if $h->{run_complete};
    }

    # Default mode should: test_job_started, test_job_completed, run_complete
    is(
        [sort @event_kinds],
        [sort qw/test_job_started test_job_completed run_complete/],
        'default mode emits per-job + run_complete',
    );
};

subtest 'verbose mode replays the 0.jsonl for each finished job' => sub {
    # Build a fake 0.jsonl with two events.
    my $dir = tempdir(CLEANUP => 1);
    my $log = "$dir/0.jsonl";
    open(my $fh, '>', $log) or die $!;
    print $fh qq({"event_id":"a","stamp":1,"facet_data":{"assert":{"pass":1,"details":"one"}}}\n);
    print $fh qq({"event_id":"b","stamp":2,"facet_data":{"assert":{"pass":1,"details":"two"}}}\n);
    close $fh;

    my $spawn = FakeSpawn->new(
        statuses => [
            {ok => 1, state => 'running',   pending => [],     running => ['j1'], done => []},
            {ok => 1, state => 'completed', pending => [],     running => [],     done => ['j1'], pass_count => 1, fail_count => 0},
        ],
        artifacts => {
            ok       => 1,
            run_id   => 'r',
            artifacts => {
                'collector:run-r:j1' => {
                    collector_id => 'collector:run-r:j1',
                    run_id       => 'r',
                    job_id       => 'j1',
                    loggers      => {
                        'Test2::Harness2::Collector::Logger::JSONL' => [
                            {output_file => $log},
                        ],
                    },
                },
            },
        },
    );

    my $r = CaptureRenderer->new;
    my $ar = App::Yath2::ArtifactReader->new(
        spawn     => $spawn,
        run_id    => 'r',
        renderers => [$r],
        mode      => 'verbose',
        poll_interval => 0.001,
    );
    $ar->run;

    # Each replayed event should appear as an event_in with the
    # assert facet the test wrote.
    my @replayed = grep {
        my $e = $_->[1];
        ref($e) eq 'HASH' && ref($e->{facet_data}) eq 'HASH'
            && ref($e->{facet_data}{assert}) eq 'HASH'
    } grep { $_->[0] eq 'event_in' } @{$r->events};

    is(scalar @replayed, 2, 'both replayed assertions landed');
    is(
        [map { $_->[1]{facet_data}{assert}{details} } @replayed],
        ['one', 'two'],
        'replay preserves order',
    );
};

subtest 'qvf mode: replay only on failure' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $log = "$dir/0.jsonl";
    open(my $fh, '>', $log) or die $!;
    print $fh qq({"event_id":"a","stamp":1,"facet_data":{"assert":{"pass":0,"details":"red"}}}\n);
    close $fh;

    my $spawn = FakeSpawn->new(
        statuses => [
            {ok => 1, state => 'completed', pending => [], running => [], done => ['j1'], pass_count => 0, fail_count => 1},
        ],
        artifacts => {
            ok       => 1,
            run_id   => 'r',
            artifacts => {
                'c' => {
                    collector_id => 'c',
                    run_id       => 'r',
                    job_id       => 'j1',
                    loggers      => {
                        'Test2::Harness2::Collector::Logger::JSONL' => [
                            {output_file => $log},
                        ],
                    },
                },
            },
        },
    );

    my $r = CaptureRenderer->new;
    my $ar = App::Yath2::ArtifactReader->new(
        spawn     => $spawn,
        run_id    => 'r',
        renderers => [$r],
        mode      => 'qvf',
        poll_interval => 0.001,
    );
    $ar->run;

    my @event_ins = grep { $_->[0] eq 'event_in' } @{$r->events};
    my @with_assert = grep {
        my $e = $_->[1];
        ref($e->{facet_data}) eq 'HASH' && ref($e->{facet_data}{assert}) eq 'HASH'
    } @event_ins;

    is(scalar @with_assert, 1, 'qvf replays the failing job');
    is($with_assert[0][1]{facet_data}{assert}{details}, 'red', 'replayed the fail line');
};

subtest 'replay_from_logs: post-run playback from an extracted archive' => sub {
    my $dir = tempdir(CLEANUP => 1);

    make_path("$dir/runs/r/jA");
    make_path("$dir/runs/r/jB");

    open(my $fh1, '>', "$dir/runs/r/jA/0.jsonl") or die $!;
    print $fh1 qq({"event_id":"1","stamp":1,"facet_data":{"assert":{"pass":1,"details":"a1"}}}\n);
    close $fh1;

    open(my $fh2, '>', "$dir/runs/r/jB/0.jsonl") or die $!;
    print $fh2 qq({"event_id":"2","stamp":2,"facet_data":{"assert":{"pass":0,"details":"b1"}}}\n);
    close $fh2;

    my $r = CaptureRenderer->new;
    App::Yath2::ArtifactReader->replay_from_logs(
        logs_dir  => $dir,
        run_id    => 'r',
        renderers => [$r],
        mode      => 'verbose',
    );

    my @details;
    for my $entry (@{$r->events}) {
        next unless $entry->[0] eq 'event_in';
        my $a = $entry->[1]{facet_data}{assert};
        push @details => $a->{details} if ref($a) eq 'HASH' && exists $a->{details};
    }
    is(\@details, ['a1', 'b1'], 'both jobs replayed in order');

    my ($end) = grep { $_->[0] eq 'end_of_run' } @{$r->events};
    ok($end, 'end_of_run fired');
};

subtest 'validation: mode and required args' => sub {
    my $spawn = FakeSpawn->new;

    my $ok = eval {
        App::Yath2::ArtifactReader->new(
            spawn     => $spawn,
            run_id    => 'r',
            renderers => [],
            mode      => 'nonesuch',
        );
        1;
    };
    ok(!$ok, 'bad mode rejected');
    like($@, qr/invalid mode/, 'error mentions mode');

    $ok = eval {
        App::Yath2::ArtifactReader->new(
            spawn     => $spawn,
            renderers => [],
        );
        1;
    };
    ok(!$ok, 'missing run_id rejected');
};

done_testing;
