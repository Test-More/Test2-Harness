use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();

use Test2::Harness2::Util::JSON qw/decode_json/;
use Test2::Harness2::Collector::Logger::JSON;

my $CLASS = 'Test2::Harness2::Collector::Logger::JSON';

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
    sub new { my ($c, %a) = @_; bless {%a}, $c }
    sub child_exit { $_[0]->{child_exit} }
}

# A minimal fake auditor with a pass() method.
{
    package T2H2_JSON_FakeAuditor;
    sub new { my ($c, $pass) = @_; bless {pass => $pass}, $c }
    sub pass { $_[0]->{pass} }
}

subtest 'required attributes' => sub {
    my $src = make_source(foo => 1);

    like(
        dies { $CLASS->new(output_file => '/tmp/x.json', spec => $src) },
        qr/ipcm_info/,
        'ipcm_info required',
    );

    like(
        dies { $CLASS->new(ipcm_info => {}, spec => $src) },
        qr/output_file/,
        'output_file required',
    );

    ok(
        $CLASS->new(ipcm_info => {}, output_file => '/tmp/x.json'),
        'spec is optional -- without it the sidecar records exit/pass only',
    );

    like(
        dies {
            $CLASS->new(
                ipcm_info   => {},
                output_file => '/tmp/x.json',
                spec      => 'not-an-object',
            )
        },
        qr/TO_JSON/,
        'spec, when provided, must be an object implementing TO_JSON',
    );
};

subtest 'log_events is false -- no per-event callbacks' => sub {
    my $dir    = tempdir(CLEANUP => 1);
    my $logger = $CLASS->new(
        ipcm_info   => {},
        output_file => "$dir/snapshot.json",
        spec      => make_source(kind => 'job'),
    );
    ok(!$logger->log_events, 'log_events returns false');
};

subtest 'metadata reports json_file' => sub {
    my $dir    = tempdir(CLEANUP => 1);
    my $logger = $CLASS->new(
        ipcm_info   => {},
        output_file => "$dir/meta.json",
        spec      => make_source(job_id => 'J1'),
    );
    is($logger->metadata, {json_file => "$dir/meta.json"},
        'metadata carries json_file locator');
};

subtest 'startup writes the source snapshot atomically' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/snapshot.json";

    my $src    = make_source(job_id => 'J1', test_file => 't/foo.t');
    my $logger = $CLASS->new(
        ipcm_info   => {},
        output_file => $path,
        spec      => $src,
    );

    $logger->startup;

    ok(-e $path, 'snapshot file exists after startup');
    my $json = do { open my $fh, '<', $path or die; local $/; <$fh> };
    my $data = decode_json($json);
    is($data, {job_id => 'J1', test_file => 't/foo.t'},
        'file contains the source TO_JSON verbatim');

    # No stray tempfiles left behind.
    opendir my $dh, $dir or die;
    my @entries = grep { !/^\./ } readdir $dh;
    closedir $dh;
    is(\@entries, ['snapshot.json'], 'no tempfile residue in the directory');
};

subtest 'shutdown appends exit status and pass verdict' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/job.json";

    my $src = make_source(
        job_id    => 'J1',
        test_file => 't/foo.t',
    );

    my $logger = $CLASS->new(
        ipcm_info   => {},
        output_file => $path,
        spec      => $src,
    );
    $logger->set_auditor(T2H2_JSON_FakeAuditor->new(1));

    $logger->startup;
    $logger->shutdown(T2H2_JSON_FakeCollector->new(child_exit => 0));

    my $json = do { open my $fh, '<', $path or die; local $/; <$fh> };
    my $data = decode_json($json);

    is($data->{job_id}, 'J1', 'original field preserved');
    is($data->{test_file}, 't/foo.t', 'original field preserved');
    is($data->{exit}, {all => 0, err => 0, sig => 0, dmp => 0},
        'exit populated from collector->child_exit');
    is($data->{pass}, 1, 'pass populated from auditor');
};

subtest 'shutdown without auditor or exit still writes the snapshot' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/noaudit.json";

    my $src    = make_source(kind => 'service');
    my $logger = $CLASS->new(
        ipcm_info   => {},
        output_file => $path,
        spec      => $src,
    );

    $logger->startup;
    $logger->shutdown(T2H2_JSON_FakeCollector->new);    # no child_exit

    my $json = do { open my $fh, '<', $path or die; local $/; <$fh> };
    my $data = decode_json($json);

    is($data->{kind}, 'service', 'original data preserved');
    ok(!exists $data->{exit}, 'no exit key when collector has no child_exit');
    ok(!exists $data->{pass}, 'no pass key when no auditor is attached');
};

subtest 'shutdown reflects non-zero exit and failing auditor' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/fail.json";

    my $src    = make_source(job_id => 'J-fail');
    my $logger = $CLASS->new(
        ipcm_info   => {},
        output_file => $path,
        spec      => $src,
    );
    $logger->set_auditor(T2H2_JSON_FakeAuditor->new(0));

    $logger->startup;
    $logger->shutdown(T2H2_JSON_FakeCollector->new(child_exit => 1 << 8));

    my $json = do { open my $fh, '<', $path or die; local $/; <$fh> };
    my $data = decode_json($json);

    is($data->{exit}{err}, 1, 'exit.err captures non-zero status');
    is($data->{pass},      0, 'pass is 0 for failing auditor');
};

done_testing;
