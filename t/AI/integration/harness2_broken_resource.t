use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep/;
use Test2::Harness2::Util::JSON qw/decode_json/;

use lib 't/lib';
use Test2::Harness2::TestFile;
use Test2::Harness2::Test::Loggers qw/classic_harness_loggers classic_test_loggers/;
use Test2::Harness2::Test::SpawnRace qw/finish_and_wait/;

use Test2::Harness2;

# End-to-end: a permanently broken resource drives a real Collector
# launch (skip_all / die) so the per-job JSONL artifacts on disk
# match what a real test would have produced.

# A tiny resource class whose is_permanent_broken is hardwired true.
# Passing it to the harness's resources list gives us a broken
# resource without needing to mark one after the fact.
{

    package Test::BrokenRes;
    use Object::HashBase;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Resource';

    sub available           { 0 }
    sub assign              { 1 }
    sub release             { 1 }
    sub status              { {broken => 1, permanent => 1} }
    sub is_permanent_broken { 1 }
    sub is_broken           { 1 }
    sub resource_name       { 'broken' }
}

sub wait_until {
    my ($check, $timeout_sec) = @_;
    my $deadline = time + $timeout_sec;
    while (time < $deadline) {
        return 1 if $check->();
        sleep(0.05);
    }
    return 0;
}

sub read_jsonl {
    my ($path) = @_;
    # Live logdirs now produce .jsonl.zst; tolerate either shape so
    # the test does not need to know which extension to ask for.
    my $zst   = ($path =~ /\.zst\z/) ? $path : "$path.zst";
    my $plain = $path =~ s/\.zst\z//r;
    if (-f $zst) {
        require Test2::Harness2::Util::JSONL::Reader;
        my $r = Test2::Harness2::Util::JSONL::Reader->new(path => $zst);
        return $r->read_lines;
    }
    open my $fh, '<', $plain or die "open $plain: $!";
    my @events = map { decode_json($_) } grep { /\S/ } <$fh>;
    close $fh;
    return @events;
}

sub facet_kind {
    my ($event) = @_;
    return $event->{facet_data}{harness}{kind} // '';
}

sub run_harness_until_drained {
    my ($dir, $spawn, $timeout) = @_;
    $timeout //= 15;
    wait_until(
        sub {
            my $s = $spawn->status;
            return !@{$s->{running} // []} && !@{$s->{queue} // []};
        },
        $timeout,
    ) or die "run never drained";

    finish_and_wait($spawn);
    return;
}

sub harness_events_for {
    my ($dir) = @_;
    return read_jsonl("$dir/logs/services/harness/events.jsonl");
}

# Under the run-service aggregation topology, per-job lifecycle
# events (job_started / job_completed / job_loggers) live in the
# run's own .jsonl, not the harness log.
sub run_events_for {
    my ($dir) = @_;
    opendir my $dh, "$dir/logs/runs" or return ();
    my @run_dirs = grep { /^[^.]/ && -d "$dir/logs/runs/$_" } readdir $dh;
    closedir $dh;
    my @out;
    for my $rid (@run_dirs) {
        for my $cand ("$dir/logs/runs/$rid/events.jsonl", "$dir/logs/runs/$rid/events.jsonl.zst") {
            next unless -e $cand;
            push @out => read_jsonl($cand);
            last;
        }
    }
    return @out;
}

subtest 'skip (default): broken resource -> unavailable-action skip_all path runs' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $tf = "$dir/never_runs.t";
    open my $fh, '>', $tf or die;
    print $fh "use Test2::V0; ok(0, 'should not run'); done_testing;\n";
    close $fh;

    my $broken = Test::BrokenRes->new;
    my $spawn  = Test2::Harness2->spawn(
        workdir         => $dir,
        resources       => [$broken],
        loggers         => classic_harness_loggers($dir),
        service_loggers => [
            'Test2::Harness2::Collector::Logger::JSONL',
            'Test2::Harness2::Collector::Logger::JSON',
        ],
        test_loggers => classic_test_loggers(),
    );
    $spawn->queue_test_run(files => [Test2::Harness2::TestFile->new(file => $tf)]);
    run_harness_until_drained($dir, $spawn);

    # The unavailable-action skip_all ran through the normal Collector
    # launch -- artifacts land on disk the same way they would for a
    # real test calling skip_all (the harness log records the
    # job_completed event; a real skip_all test exits with the same
    # status under this collector, preexisting behavior).
    my @events    = run_events_for($dir);
    my @completed = grep { facet_kind($_) eq 'job_completed' } @events;
    is(scalar @completed, 1, 'exactly one job_completed event in the run log');
};

subtest 'fail: broken resource -> unavailable-action die, non-zero exit' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $tf = "$dir/never_runs.t";
    open my $fh, '>', $tf or die;
    print $fh "use Test2::V0; ok(0, 'should not run'); done_testing;\n";
    close $fh;

    my $broken = Test::BrokenRes->new;
    my $spawn  = Test2::Harness2->spawn(
        workdir                  => $dir,
        resources                => [$broken],
        broken_resource_behavior => 'fail',
        loggers                  => classic_harness_loggers($dir),
        service_loggers          => [
            'Test2::Harness2::Collector::Logger::JSONL',
            'Test2::Harness2::Collector::Logger::JSON',
        ],
        test_loggers => classic_test_loggers(),
    );
    $spawn->queue_test_run(files => [Test2::Harness2::TestFile->new(file => $tf)]);
    run_harness_until_drained($dir, $spawn);

    my @events    = run_events_for($dir);
    my @completed = grep { facet_kind($_) eq 'job_completed' } @events;
    is(scalar @completed, 1, 'exactly one job_completed event in the run log');

    # Run service now emits the raw wait-status int under 'exit' and
    # the parsed { err, sig, dmp } hash under 'codes'.
    my $codes = $completed[0]{facet_data}{harness}{codes};
    isnt($codes->{err}, 0, 'fail unavailable-action exits non-zero (die)');
};

subtest 'abort: every queued job gets an unavailable-action launch even for multiple tests' => sub {
    my $dir = tempdir(CLEANUP => 1);

    for my $n (1 .. 3) {
        my $tf = "$dir/never_$n.t";
        open my $fh, '>', $tf or die;
        print $fh "use Test2::V0; ok(0); done_testing;\n";
        close $fh;
    }

    my $broken = Test::BrokenRes->new;
    my $spawn  = Test2::Harness2->spawn(
        workdir                  => $dir,
        resources                => [$broken],
        broken_resource_behavior => 'abort',
        loggers                  => classic_harness_loggers($dir),
        service_loggers          => [
            'Test2::Harness2::Collector::Logger::JSONL',
            'Test2::Harness2::Collector::Logger::JSON',
        ],
        test_loggers => classic_test_loggers(),
    );
    $spawn->queue_test_run(
        files => [
            map { Test2::Harness2::TestFile->new(file => "$dir/never_$_.t") } 1 .. 3,
        ],
    );
    run_harness_until_drained($dir, $spawn, 30);

    my @events    = run_events_for($dir);
    my @completed = grep { facet_kind($_) eq 'job_completed' } @events;
    is(scalar @completed, 3, 'every job produced a job_completed event under abort');
};

done_testing;
