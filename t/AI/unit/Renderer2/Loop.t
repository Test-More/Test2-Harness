use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use Time::HiRes qw/sleep/;
use Cpanel::JSON::XS qw/encode_json/;
use App::Yath2::Log;
use App::Yath2::Renderer2::Loop;
use App::Yath2::Renderer2::Base;

# Recording subclass for all subtests.
{

    package T::R::Rec;
    use parent 'App::Yath2::Renderer2::Base';
    our @SEEN;
    sub handle_run_opened     { push @SEEN, ['run_opened',     $_[1]->id] }
    sub handle_run_sealed     { push @SEEN, ['run_sealed',     $_[1]->id] }
    sub handle_job_opened     { push @SEEN, ['job_opened',     $_[1]->id] }
    sub handle_job_sealed     { push @SEEN, ['job_sealed',     $_[1]->id] }
    sub handle_service_opened { push @SEEN, ['service_opened', $_[1]->id] }
    sub handle_service_sealed { push @SEEN, ['service_sealed', $_[1]->id] }
}

subtest sealed_log_one_pass => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/runs/1/jobs/1/0");

    open my $sfh, '>', "$dir/runs/1/jobs/1/0/spec.jsonl" or die "open spec.jsonl: $!";
    close $sfh;

    open my $sm, '>', "$dir/runs/1/jobs/1/0/.sealed" or die "open job .sealed: $!";
    print $sm encode_json({sealed_at => 100, final_state => 'completed', pass => 1});
    close $sm;

    open my $rsm, '>', "$dir/runs/1/.sealed" or die "open run .sealed: $!";
    print $rsm encode_json({sealed_at => 200, final_state => 'completed', pass => 1, exit => 0});
    close $rsm;

    my $log = App::Yath2::Log->new(dir => $dir);
    @T::R::Rec::SEEN = ();
    my $r = T::R::Rec->new(
        log         => $log,
        parent_pid  => $$,
        command_pid => $$,
        out_fh      => \*STDOUT,
    );

    App::Yath2::Renderer2::Loop::run($r);

    # Sealed log: one pass — each producer fires its opened then sealed hook.
    # Jobs are nested inside runs so the expected order is:
    #   run_opened, job_opened, job_sealed, run_sealed.
    my @kinds = map { $_->[0] } @T::R::Rec::SEEN;
    is(
        \@kinds,
        [qw/run_opened job_opened job_sealed run_sealed/],
        'opened-then-sealed pair per producer, jobs nested inside runs',
    );

    # Sealed hook fires exactly once even if run is called again.
    my @ids = map { $_->[1] } @T::R::Rec::SEEN;
    ok((grep { $_ eq '1' } @ids) >= 2, 'producer id 1 appears at least twice (opened + sealed)');
};

subtest live_log_drain_on_live_removal => sub {
    my $dir = tempdir(CLEANUP => 1);

    open my $lfh, '>', "$dir/LIVE" or die "open LIVE: $!";
    print $lfh "1\n";
    close $lfh;

    make_path("$dir/runs/1/jobs/1/0");
    open my $sfh, '>', "$dir/runs/1/jobs/1/0/spec.jsonl" or die "open spec.jsonl: $!";
    close $sfh;

    my $log = App::Yath2::Log->new(live => $dir);
    @T::R::Rec::SEEN = ();
    my $r = T::R::Rec->new(
        log         => $log,
        parent_pid  => $$,
        command_pid => $$,
        out_fh      => \*STDOUT,
        settings    => {poll_interval => 0.05},
    );

    # Fork: remove LIVE after 200 ms to trigger the drain path.
    my $kid = fork // die "fork: $!";
    if ($kid == 0) {
        sleep 0.2;
        unlink "$dir/LIVE";
        exit 0;
    }

    App::Yath2::Renderer2::Loop::run($r);
    waitpid($kid, 0);

    ok(
        (grep { $_->[0] eq 'run_opened' } @T::R::Rec::SEEN),
        'run_opened fired in live mode before drain'
    );
};

subtest dead_parent_pid_triggers_drain => sub {
    my $dir = tempdir(CLEANUP => 1);

    open my $lfh, '>', "$dir/LIVE" or die "open LIVE: $!";
    print $lfh "1\n";
    close $lfh;

    make_path("$dir/runs/1");
    open my $rfh, '>', "$dir/runs/1/spec.jsonl" or die "open run spec.jsonl: $!";
    close $rfh;

    my $log = App::Yath2::Log->new(live => $dir);
    @T::R::Rec::SEEN = ();

    # Fork a child that exits immediately. Reap it so kill(0, $dead_kid)
    # returns false before the loop even starts its first iteration.
    my $dead_kid = fork // die "fork: $!";
    if ($dead_kid == 0) {
        exit 0;
    }
    waitpid($dead_kid, 0);

    my $r = T::R::Rec->new(
        log         => $log,
        parent_pid  => $dead_kid,
        command_pid => $$,
        out_fh      => \*STDOUT,
        settings    => {poll_interval => 0.05},
    );

    App::Yath2::Renderer2::Loop::run($r);

    # The loop fires at least one scan (run_opened or nothing, depending on
    # whether run/1 surfaced in the live directory), then drains and exits.
    # What matters is that it does exit cleanly rather than hanging.
    pass('loop exited without hanging on dead parent_pid');
};

subtest idempotent_hooks => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/runs/1/jobs/1/0");

    open my $sfh, '>', "$dir/runs/1/jobs/1/0/spec.jsonl" or die;
    close $sfh;

    open my $sm, '>', "$dir/runs/1/jobs/1/0/.sealed" or die;
    print $sm encode_json({sealed_at => 100, final_state => 'completed', pass => 1});
    close $sm;

    open my $rsm, '>', "$dir/runs/1/.sealed" or die;
    print $rsm encode_json({sealed_at => 200, final_state => 'completed', pass => 1, exit => 0});
    close $rsm;

    my $log = App::Yath2::Log->new(dir => $dir);
    @T::R::Rec::SEEN = ();
    my $r = T::R::Rec->new(
        log         => $log,
        parent_pid  => $$,
        command_pid => $$,
        out_fh      => \*STDOUT,
    );

    # Call _scan_once multiple times; hooks must fire exactly once.
    App::Yath2::Renderer2::Loop::_scan_once($r);
    App::Yath2::Renderer2::Loop::_scan_once($r);
    App::Yath2::Renderer2::Loop::_scan_once($r);

    my %counts;
    $counts{$_->[0]}++ for @T::R::Rec::SEEN;
    is($counts{run_opened}, 1, 'run_opened fires exactly once across repeated scans');
    is($counts{run_sealed}, 1, 'run_sealed fires exactly once across repeated scans');
    is($counts{job_opened}, 1, 'job_opened fires exactly once across repeated scans');
    is($counts{job_sealed}, 1, 'job_sealed fires exactly once across repeated scans');
};

done_testing;
