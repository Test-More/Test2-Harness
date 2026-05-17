use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use Cpanel::JSON::XS qw/encode_json/;
use App::Yath2::Log;

my $dir = tempdir(CLEANUP => 1);

# LIVE sentinel makes this a live-mode log.
open my $lfh, '>', "$dir/LIVE" or die "open LIVE: $!";
print $lfh "1\n";
close $lfh;

make_path("$dir/runs/1/jobs/1/0");

open my $sfh, '>', "$dir/runs/1/jobs/1/0/spec.jsonl" or die "open spec.jsonl: $!";
print $sfh qq[{"job_id":"1","try":0}\n];
close $sfh;

my $log = App::Yath2::Log->new(live => $dir);

my @jobs = $log->job_producers('1')->all;
is(scalar(@jobs),   1,         'one job descriptor');
is($jobs[0]->state, 'partial', 'partial in live mode without .sealed');

# Now drop a .sealed marker, re-iterate.
open my $sm, '>', "$dir/runs/1/jobs/1/0/.sealed" or die "open .sealed: $!";
print $sm encode_json({sealed_at => 100, final_state => 'completed', pass => 1});
close $sm;

@jobs = $log->job_producers('1')->all;
is($jobs[0]->state, 'sealed', 'sealed once .sealed appears');
is($jobs[0]->pass,  1,        'pass from .sealed marker');

done_testing;
