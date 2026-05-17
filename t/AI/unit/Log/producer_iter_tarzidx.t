use Test2::V0;
use File::Temp qw/tempdir tempfile/;
use File::Path qw/make_path/;
use Cpanel::JSON::XS qw/encode_json/;
use App::Yath2::Log;

my $dir = tempdir(CLEANUP => 1);
make_path("$dir/runs/1/jobs/1/0");
open my $sfh, '>', "$dir/runs/1/jobs/1/0/spec.jsonl" or die "open: $!";
print $sfh qq[{"job_id":"1","try":0}\n];
close $sfh;
open my $sm, '>', "$dir/runs/1/jobs/1/0/.sealed" or die "open: $!";
print $sm encode_json({sealed_at => 100, final_state => 'completed', pass => 1});
close $sm;
open my $rsm, '>', "$dir/runs/1/.sealed" or die "open: $!";
print $rsm encode_json({sealed_at => 200, final_state => 'completed', pass => 1, exit => 0});
close $rsm;

my ($tfh, $tarpath) = tempfile(SUFFIX => '.yath', UNLINK => 1);
close $tfh;
App::Yath2::Log->new(dir => $dir)->archive($tarpath);

my $log = App::Yath2::Log->new(file => $tarpath);

# {{{ run_producers

subtest 'run_producers' => sub {
    my @runs = $log->run_producers->all;
    is(scalar(@runs),   1,        'one run');
    is($runs[0]->id,    '1',      'run id');
    is($runs[0]->state, 'sealed', 'tar runs always sealed');
    is($runs[0]->pass,  1,        'pass from .sealed survived archive');
    is($runs[0]->exit,  0,        'exit from .sealed survived archive');
};

# }}}

# {{{ job_producers

subtest 'job_producers' => sub {
    my @jobs = $log->job_producers('1')->all;
    is(scalar(@jobs),   1,        'one job');
    is($jobs[0]->id,    '1',      'job id');
    is($jobs[0]->state, 'sealed', 'job .sealed survived archive');
    is($jobs[0]->pass,  1,        'job pass from .sealed');
    ok(defined $jobs[0]->artifact_refs->{spec}, 'spec artifact ref present in tar');
};

# }}}

# {{{ service_producers and collector_producers return empty iterators

subtest 'service_producers returns empty iterator (no services in fixture)' => sub {
    my @svcs = $log->service_producers->all;
    is(scalar(@svcs), 0, 'no global services');

    my @run_svcs = $log->service_producers('1')->all;
    is(scalar(@run_svcs), 0, 'no run-scoped services');
};

subtest 'collector_producers returns empty iterator' => sub {
    my @cols = $log->collector_producers->all;
    is(scalar(@cols), 0, 'no collectors');
};

# }}}

done_testing;
