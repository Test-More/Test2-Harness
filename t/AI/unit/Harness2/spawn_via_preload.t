use Test2::V0;
use File::Temp qw/tempdir/;
use Test2::Util::UUID qw/gen_uuid/;

use lib 't/lib';
use Test2::Harness2;
use Test2::Harness2::Resource::Preload;
use Test2::Harness2::TestFile;
use Test2::Harness2::Run;
use Test2::Harness2::Run::Job;
use Test2::Harness2::Run::State;

sub mk_harness {
    my (%opts) = @_;
    my $dir = tempdir(CLEANUP => 1);
    return Test2::Harness2->new(workdir => $dir, %opts);
}

sub mk_job_and_run {
    my $dir = tempdir(CLEANUP => 1);
    my $tf_path = "$dir/foo.t";
    open my $fh, '>', $tf_path or die $!;
    print $fh "use Test2::V0; ok(1); done_testing;\n";
    close $fh;

    my $run_id = gen_uuid();
    my $run = Test2::Harness2::Run->new(
        run_id => $run_id,
        jobs   => [],
    );
    my $tf = Test2::Harness2::TestFile->new(file => $tf_path);
    my $job = Test2::Harness2::Run::Job->new(
        job_id    => gen_uuid(),
        run_id    => $run_id,
        test_file => $tf,
    );
    return ($run, $job);
}

# Capture sends instead of going to the bus.
my @sent;
sub stub_client {
    my ($h) = @_;
    my $client = bless { sent => \@sent }, 'Test::SpawnClient';
    no warnings 'redefine';
    no strict 'refs';
    *Test2::Harness2::client = sub { $client };
    use strict;
    *Test::SpawnClient::send_message = sub {
        my ($self, $peer, $payload) = @_;
        push @{$self->{sent}}, [$peer, $payload];
        return 1;
    };
}

subtest 'spawn_via_preload records placeholder + sends spawn_test' => sub {
    @sent = ();
    my $preload = Test2::Harness2::Resource::Preload->new(name => 'default', modules => []);
    $preload->mark_ready;
    my $h = mk_harness(resources => [$preload]);
    stub_client($h);

    my ($run, $job) = mk_job_and_run();

    $h->preload_router->spawn_via_preload($run, $job, $preload,
        env                => { FOO => 'bar' },
        assign_id          => 'AID',
        assigned_resources => [$preload],
    );

    my $cur = $h->job_tracker->running_jobs->{$job->job_id};
    ok($cur, 'placeholder running job entry exists');
    ok(!defined $cur->{pid}, 'pid is undef on placeholder');
    is($cur->{awaiting_preload_pid}, 1,            'awaiting_preload_pid set');
    is($cur->{preload_name},         'default',    'preload_name carried');
    is($cur->{preload_scope},        'global',     'preload_scope carried');
    is($cur->{assign_id},            'AID',        'assign_id stored');

    my $pending = $h->preload_router->{Test2::Harness2::PENDING_SPAWN_REQUESTS()};
    my $key = $run->run_id . "\0" . $job->job_id;
    ok($pending->{$key}, 'pending spawn request keyed by run+job');

    is(scalar @sent, 1, 'one IPC message sent');
    my ($peer, $payload) = @{$sent[0]};
    is($peer, 'preload-default', 'sent to bus name preload-<name>');
    is($payload->{kind},          'spawn_test',         'kind=spawn_test');
    is($payload->{run_id},        $run->run_id,         'run_id carried');
    is($payload->{job_id},        $job->job_id,         'job_id carried');
    like($payload->{test_file_abs}, qr{\.t$},           'test_file_abs is the .t');
    is($payload->{env}->{FOO},    'bar',                'env passed through');
    is($payload->{env}->{T2_FORMATTER}, 'Stream2',      'T2_FORMATTER injected');
};

subtest 'handle_test_job_started populates placeholder pid' => sub {
    @sent = ();
    my $preload = Test2::Harness2::Resource::Preload->new(name => 'default', modules => []);
    $preload->mark_ready;
    my $h = mk_harness(resources => [$preload]);
    stub_client($h);

    my ($run, $job) = mk_job_and_run();
    # Scheduler entry so mark_running doesn't choke if test_job_started triggers a state lookup.
    $h->scheduler->scheduler_table->{$run->run_id} = {pending => [], running => {}, started => 1};
    # Seed the run state so mark_running succeeds.
    $h->{Test2::Harness2::RUN_STATES()}->{$run->run_id} = Test2::Harness2::Run::State->new(run_id => $run->run_id);
    $h->{Test2::Harness2::RUN_STATES()}->{$run->run_id}->seed_job_result($job->job_id);

    $h->preload_router->spawn_via_preload($run, $job, $preload, assign_id => 'AID', assigned_resources => [$preload]);

    # Capture run_state subscriber to no-op so broadcast_run_state doesn't blow up.
    no warnings 'redefine';
    local *Test2::Harness2::StateBroadcaster::broadcast_run_state = sub { };
    use warnings;

    $h->job_tracker->handle_test_job_started({
        run_id        => $run->run_id,
        job_id        => $job->job_id,
        job_try       => 1,
        collector_pid => 99999,
        stamp         => 1234,
    });

    my $cur = $h->job_tracker->running_jobs->{$job->job_id};
    is($cur->{pid}, 99999, 'pid populated from collector_pid');
    ok(!exists $cur->{awaiting_preload_pid}, 'awaiting flag cleared');

    my $pending = $h->preload_router->{Test2::Harness2::PENDING_SPAWN_REQUESTS()};
    my $key = $run->run_id . "\0" . $job->job_id;
    ok(!$pending->{$key}, 'pending spawn dropped');
};

subtest 'age_pending_spawn_requests times out + flips broken' => sub {
    @sent = ();
    my $preload = Test2::Harness2::Resource::Preload->new(name => 'default', modules => []);
    $preload->mark_ready;
    my $h = mk_harness(resources => [$preload], preload_spawn_timeout_secs => 0);
    stub_client($h);

    my ($run, $job) = mk_job_and_run();
    $h->scheduler->scheduler_table->{$run->run_id} = {pending => [], running => {}, started => 1};

    $h->preload_router->spawn_via_preload($run, $job, $preload, assign_id => 'AID', assigned_resources => []);

    # backdate sent_at so the watchdog fires
    my $key = $run->run_id . "\0" . $job->job_id;
    $h->preload_router->{Test2::Harness2::PENDING_SPAWN_REQUESTS()}->{$key}->{sent_at} = time - 60;

    # Silence warn during age sweep
    local $SIG{__WARN__} = sub { };
    $h->preload_router->_age_pending_spawn_requests;

    ok(!$h->job_tracker->running_jobs->{$job->job_id}, 'placeholder dropped');
    ok(!$h->preload_router->{Test2::Harness2::PENDING_SPAWN_REQUESTS()}->{$key}, 'pending dropped');
    ok($preload->is_broken,          'preload flipped transient broken');
    ok(!$preload->is_permanent_broken, 'not permanent');
    # And the job is back in the pending list
    is($h->scheduler->scheduler_table->{$run->run_id}->{pending}, [$job->job_id],
        'job re-queued as pending');
};

done_testing;
