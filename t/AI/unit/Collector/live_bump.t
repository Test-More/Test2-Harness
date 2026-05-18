use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep stat/;
use Test2::Harness2::Collector;

my $dir = tempdir(CLEANUP => 1);

# Pre-seed LIVE as _create_live_sentinel would.
open my $sfh, '>', "$dir/LIVE" or die;
print $sfh "1\n";
close $sfh;
my $initial_mtime = (stat "$dir/LIVE")[9];

sleep 0.05;    # ensure measurable mtime delta

my $self = bless {Test2::Harness2::Collector::LOGDIR() => $dir}, 'Test2::Harness2::Collector';
Test2::Harness2::Collector::_live_bump($self);

my $bumped_mtime = (stat "$dir/LIVE")[9];
ok($bumped_mtime > $initial_mtime, 'mtime bumped after _live_bump')
    or note("initial=$initial_mtime bumped=$bumped_mtime");

# LIVE content unchanged (still just "1\n").
open my $rfh, '<', "$dir/LIVE" or die;
my $content = do { local $/; <$rfh> };
close $rfh;
is($content, "1\n", 'LIVE content unchanged');

# _live_bump on a non-existent LIVE is a no-op (doesn't die).
unlink "$dir/LIVE";
ok(lives { Test2::Harness2::Collector::_live_bump($self) }, '_live_bump no-ops when LIVE absent');

done_testing;
