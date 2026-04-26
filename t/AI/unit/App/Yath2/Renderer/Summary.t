use Test2::V0;

use App::Yath2::Renderer::Summary;

my $CLASS = 'App::Yath2::Renderer::Summary';

sub make_renderer {
    return $CLASS->new(@_);
}

sub ev {
    my (%fd) = @_;
    return {event_id => 'test-id', stamp => 1, facet_data => \%fd};
}

subtest 'desired_filters returns empty list' => sub {
    my $r = make_renderer();
    my @f = $r->desired_filters;
    is(scalar @f, 0, 'no filters — sees all lifecycle events');
};

subtest 'render_event accumulates harness_run_end' => sub {
    my $r = make_renderer();
    $r->render_event(ev(
        harness_run_end => {
            run_id     => 'run-1',
            pass       => 1,
            pass_count => 5,
            fail_count => 0,
            stamp      => 999,
        }
    ));
    ok(defined $r->{+App::Yath2::Renderer::Summary::_RUN_END()}, '_run_end set');
    is($r->{+App::Yath2::Renderer::Summary::_RUN_END()}{pass}, 1, 'pass stored');
    is($r->{+App::Yath2::Renderer::Summary::_RUN_END()}{pass_count}, 5, 'pass_count stored');
};

subtest 'render_event accumulates failed jobs from harness_job_end' => sub {
    my $r = make_renderer();

    $r->render_event(ev(
        harness_job_end => {job_id => 'j1', rel_file => 't/pass.t', fail => 0}
    ));
    $r->render_event(ev(
        harness_job_end => {job_id => 'j2', rel_file => 't/fail.t', fail => 1}
    ));

    my $failed = $r->{+App::Yath2::Renderer::Summary::_FAILED_JOBS()};
    is(scalar @$failed, 1, 'only one failed job recorded');
    is($failed->[0][0], 'j2', 'correct job_id');
    is($failed->[0][1], 't/fail.t', 'correct file');
};

subtest 'render_summary prints pass result' => sub {
    my $r   = make_renderer();
    my $buf = '';
    local *STDOUT;
    open(STDOUT, '>', \$buf) or die "Cannot redirect STDOUT: $!";
    $r->render_summary({pass => 1, pass_count => 3, fail_count => 0});
    close STDOUT;
    open(STDOUT, '>&', \*STDERR);    # restore to something
    like($buf, qr/PASSED/, 'PASSED in output');
    like($buf, qr/File Count: 3/, 'file count shown');
};

subtest 'render_summary shows timing when present' => sub {
    my $r   = make_renderer();
    my $buf = '';
    local *STDOUT;
    open(STDOUT, '>', \$buf) or die "Cannot redirect STDOUT: $!";
    $r->render_summary({
        pass       => 1,
        pass_count => 2,
        fail_count => 0,
        wall_time  => 10.5,
        cpu_times  => [2.1, 0.3, 5.0, 0.1],
        cpu_total  => 7.5,
        cpu_usage  => 71,
    });
    close STDOUT;
    open(STDOUT, '>&', \*STDERR);
    like($buf, qr/Wall Time.*10\.5000s/, 'wall time shown');
    like($buf, qr/CPU Time/, 'cpu time shown');
    like($buf, qr/CPU Usage.*71%/, 'cpu usage shown');
    like($buf, qr/usr:.*2\.10000s/, 'user time shown');
};

subtest 'render_summary prints fail result' => sub {
    my $r   = make_renderer();
    my $buf = '';
    local *STDOUT;
    open(STDOUT, '>', \$buf) or die "Cannot redirect STDOUT: $!";
    $r->render_summary({pass => 0, pass_count => 2, fail_count => 1});
    close STDOUT;
    open(STDOUT, '>&', \*STDERR);
    like($buf, qr/FAILED/, 'FAILED in output');
    like($buf, qr/Fail Count: 1/, 'fail count shown');
    like($buf, qr/File Count: 3/, 'total file count shown');
};

subtest 'finish outputs summary from accumulated state' => sub {
    my $r = make_renderer();

    $r->render_event(ev(
        harness_run_end => {pass => 1, pass_count => 2, fail_count => 0}
    ));

    my $buf = '';
    local *STDOUT;
    open(STDOUT, '>', \$buf) or die "Cannot redirect STDOUT: $!";
    $r->finish;
    close STDOUT;
    open(STDOUT, '>&', \*STDERR);
    like($buf, qr/PASSED/, 'PASSED shown in finish output');
};

subtest 'write_summary_file skips when no file configured' => sub {
    my $r = make_renderer();
    ok(lives { $r->write_summary_file({}) }, 'no die when no file set');
};

done_testing;
