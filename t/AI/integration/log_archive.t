use Test2::V0;

use File::Temp qw/tempdir tempfile/;
use Time::HiRes qw/sleep/;

use lib 't/lib';
use Test2::Harness2::TestFile;
use Test2::Harness2::Test::Loggers qw/classic_harness_loggers classic_test_loggers/;
use Test2::Harness2;
use App::Yath2::LogArchive;

sub wait_until {
    my ($check, $timeout_sec) = @_;
    my $deadline = time + $timeout_sec;
    while (time < $deadline) {
        return 1 if $check->();
        sleep(0.05);
    }
    return 0;
}

my $dir = tempdir(CLEANUP => 1);

my $tf = "$dir/quick.t";
open my $fh, '>', $tf or die;
print $fh "use Test2::V0; ok(1); done_testing;\n";
close $fh;

my $spawn = Test2::Harness2->spawn(
    workdir         => $dir,
    kill_timeout    => 5,
    loggers         => classic_harness_loggers($dir),
    service_loggers => classic_test_loggers(),
    test_loggers    => classic_test_loggers(),
);

$spawn->queue_test_run(files => [Test2::Harness2::TestFile->new(file => $tf)]);

wait_until(
    sub {
        my $s = $spawn->status;
        return !@{$s->{running} // []} && !@{$s->{queue} // []};
    },
    30
) or die "run did not complete";

$spawn->finish;
$spawn->wait;

my $dir_la = App::Yath2::LogArchive->open(path => "$dir/logs");
isa_ok($dir_la, 'App::Yath2::LogArchive::Directory');

my @runs = $dir_la->runs;
is(scalar(@runs), 1, 'exactly one run on disk');
my $run_id = $runs[0];

my $global = $dir_la->artifacts;
ok(
    (grep { m{^services/} } keys %{$global->{append} // {}}, keys %{$global->{replace} // {}}),
    'global artifacts include at least one services/ entry'
);

my $run_scope = $dir_la->artifacts($run_id);
ok(
    scalar(keys %{$run_scope->{append} // {}}) + scalar(keys %{$run_scope->{replace} // {}}),
    'per-run artifacts non-empty'
);

my (undef, $archive) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
unlink $archive;
App::Yath2::LogArchive->open(dir => "$dir/logs")->archive($archive);
ok(-s $archive, 'archive non-empty');

my $arc_la = App::Yath2::LogArchive->open(path => $archive);
ok(
    ref($arc_la) =~ /^App::Yath2::LogArchive::TarZIdx/,
    'opened tar.zidx backend (' . ref($arc_la) . ')'
);

is($arc_la->artifacts,          $dir_la->artifacts,          'global artifacts round-trip');
is([$arc_la->runs],             [$dir_la->runs],             'runs round-trip');
is($arc_la->artifacts($run_id), $dir_la->artifacts($run_id), 'run artifacts round-trip');

done_testing;
