use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();

use Test2::Harness2::Util::File::JSON::Zstd;
use Test2::Harness2::Collector::Logger::JSON;

my $CLASS = 'Test2::Harness2::Collector::Logger::JSON';

# Read back a snapshot file written by Logger::JSON.
sub read_snapshot {
    my ($path) = @_;
    return Test2::Harness2::Util::File::JSON::Zstd->new(name => $path)->read;
}

# A minimal fake with a TO_JSON method we can verify round-trips cleanly.
{

    package T2H2_JSON_FakeSource;
    sub new { my ($c, %a) = @_; bless {%a}, $c }
    sub TO_JSON { my $self = shift; return {%{$self->{data} // {}}} }
}

sub make_source { T2H2_JSON_FakeSource->new(data => {@_}) }

# A minimal fake collector that just advertises a child_exit value.
{

    package T2H2_JSON_FakeCollector;
    sub new        { my ($c, %a) = @_; bless {%a}, $c }
    sub child_exit { $_[0]->{child_exit} }
}

# A minimal fake auditor with a pass() method.
{

    package T2H2_JSON_FakeAuditor;
    sub new  { my ($c, $pass) = @_; bless {pass => $pass}, $c }
    sub pass { $_[0]->{pass} }
}

subtest 'required attributes' => sub {
    my $src = make_source(foo => 1);

    like(
        dies { $CLASS->new(output_file => '/tmp/x.json.zst', spec => $src) },
        qr/ipcm_info/,
        'ipcm_info required',
    );

    # Logger-paths refactor: output_file is derived from collector
    # identity attributes when not supplied, so the constructor no
    # longer croaks on its absence.
    ok(
        $CLASS->new(ipcm_info => {}, spec => $src),
        'output_file is optional (derived from identity when absent)',
    );

    ok(
        $CLASS->new(ipcm_info => {}, output_file => '/tmp/x.json.zst'),
        'spec is optional -- without it the sidecar records exit/pass only',
    );

    like(
        dies {
            $CLASS->new(
                ipcm_info   => {},
                output_file => '/tmp/x.json.zst',
                spec        => 'not-an-object',
            )
        },
        qr/TO_JSON/,
        'spec, when provided, must be an object implementing TO_JSON',
    );
};

subtest 'output_file is lazily resolved from identity attributes' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $logger = $CLASS->new(
        ipcm_info    => {},
        logdir       => $dir,
        service_name => 'run',
        run_id       => 'R1',
        is_run       => 1,
    );

    my ($path) = $logger->output_files;
    is($path, "$dir/runs/R1/state.json.zst",
        'output_files derives $logdir/runs/<run_id>/state.json.zst when is_run is set');

    my $bare = $CLASS->new(ipcm_info => {});
    like(
        dies { $bare->output_files },
        qr/logdir/,
        'output_files croaks when neither output_file nor logdir is available',
    );
};

subtest 'log_events is true (consumes run_mutation events)' => sub {
    my $dir    = tempdir(CLEANUP => 1);
    my $logger = $CLASS->new(
        ipcm_info   => {},
        output_file => "$dir/snapshot.json.zst",
        spec        => make_source(kind => 'job'),
    );
    ok($logger->log_events, 'log_events returns true');
};

subtest 'run_mutation events are cached and win over the startup spec' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/mut.json.zst";

    my $logger = $CLASS->new(
        ipcm_info   => {},
        output_file => $path,
        spec        => make_source(run_id => 'R', pending => [qw/a b/], running => [], done => []),
    );
    $logger->startup;

    # After startup the file carries the spec's TO_JSON.
    my $at_start = read_snapshot($path);
    is($at_start->{pending}, [qw/a b/], 'startup wrote the spec snapshot');

    # A run_mutation event arrives with a fresher snapshot.
    my $fake_event = bless {
        facet_data => {
            harness => {
                kind     => 'run_mutation',
                run_data => {run_id => 'R', pending => ['b'], running => ['a'], done => []},
            },
        },
        },
        'Test::FakeJsonEvent';
    no warnings 'once';
    *Test::FakeJsonEvent::facet_data = sub { $_[0]->{facet_data} };

    $logger->log_event($fake_event);
    $logger->shutdown;

    my $at_end = read_snapshot($path);
    is($at_end->{pending}, ['b'], 'shutdown wrote the latest run_mutation payload');
    is($at_end->{running}, ['a'], 'running list from run_mutation');
};

subtest 'metadata reports json_file' => sub {
    my $dir    = tempdir(CLEANUP => 1);
    my $logger = $CLASS->new(
        ipcm_info   => {},
        output_file => "$dir/meta.json.zst",
        spec        => make_source(job_id => 'J1'),
    );
    is(
        $logger->metadata, {json_file => "$dir/meta.json.zst"},
        'metadata carries json_file locator'
    );
};

subtest 'startup writes the source snapshot atomically' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/snapshot.json.zst";

    my $src    = make_source(job_id => 'J1', test_file => 't/foo.t');
    my $logger = $CLASS->new(
        ipcm_info   => {},
        output_file => $path,
        spec        => $src,
    );

    $logger->startup;

    ok(-e $path, 'snapshot file exists after startup');
    my $data = read_snapshot($path);
    is(
        $data, {job_id => 'J1', test_file => 't/foo.t'},
        'file contains the source TO_JSON verbatim'
    );

    # No stray tempfiles left behind.
    opendir my $dh, $dir or die;
    my @entries = grep { !/^\./ } readdir $dh;
    closedir $dh;
    is(\@entries, ['snapshot.json.zst'], 'no tempfile residue in the directory');
};

subtest 'shutdown appends exit status and pass verdict' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/job.json.zst";

    my $src = make_source(
        job_id    => 'J1',
        test_file => 't/foo.t',
    );

    my $logger = $CLASS->new(
        ipcm_info   => {},
        output_file => $path,
        spec        => $src,
    );
    $logger->set_auditor(T2H2_JSON_FakeAuditor->new(1));

    $logger->startup;
    $logger->shutdown(T2H2_JSON_FakeCollector->new(child_exit => 0));

    my $data = read_snapshot($path);

    is($data->{job_id},    'J1',      'original field preserved');
    is($data->{test_file}, 't/foo.t', 'original field preserved');
    is(
        $data->{exit}, {all => 0, err => 0, sig => 0, dmp => 0},
        'exit populated from collector->child_exit'
    );
    is($data->{pass}, 1, 'pass populated from auditor');
};

subtest 'shutdown without auditor or exit still writes the snapshot' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/noaudit.json.zst";

    my $src    = make_source(kind => 'service');
    my $logger = $CLASS->new(
        ipcm_info   => {},
        output_file => $path,
        spec        => $src,
    );

    $logger->startup;
    $logger->shutdown(T2H2_JSON_FakeCollector->new);    # no child_exit

    my $data = read_snapshot($path);

    is($data->{kind}, 'service', 'original data preserved');
    ok(!exists $data->{exit}, 'no exit key when collector has no child_exit');
    ok(!exists $data->{pass}, 'no pass key when no auditor is attached');
};

subtest 'shutdown reflects non-zero exit and failing auditor' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/fail.json.zst";

    my $src    = make_source(job_id => 'J-fail');
    my $logger = $CLASS->new(
        ipcm_info   => {},
        output_file => $path,
        spec        => $src,
    );
    $logger->set_auditor(T2H2_JSON_FakeAuditor->new(0));

    $logger->startup;
    $logger->shutdown(T2H2_JSON_FakeCollector->new(child_exit => 1 << 8));

    my $data = read_snapshot($path);

    is($data->{exit}{err}, 1, 'exit.err captures non-zero status');
    is($data->{pass},      0, 'pass is 0 for failing auditor');
};

done_testing;
