use Test2::V0;
use File::Temp qw/tempdir/;
use Test2::Harness2::Collector;

my $dir = tempdir(CLEANUP => 1);

# Pre-seed the LIVE sentinel as the real _create_live_sentinel would.
open my $sfh, '>', "$dir/LIVE" or die;
print $sfh "1\n";
close $sfh;

# Invoke the helper directly with a synthetic collector + payload.
my $self = bless {Test2::Harness2::Collector::LOGDIR() => $dir}, 'Test2::Harness2::Collector';
Test2::Harness2::Collector::_live_append(
    $self,
    {
        k     => 'producer',
        kind  => 'job',
        id    => 'job-1',
        state => 'open',
        ts    => 100,
    }
);
Test2::Harness2::Collector::_live_append(
    $self,
    {
        k     => 'producer',
        kind  => 'job',
        id    => 'job-1',
        state => 'close',
        ts    => 200,
    }
);

open my $rfh, '<', "$dir/LIVE" or die;
my @lines = <$rfh>;
close $rfh;
is(scalar(@lines), 3, '1 sentinel line + 2 appended');
like($lines[1], qr/"state":"open"/,  'open line');
like($lines[2], qr/"state":"close"/, 'close line');
like($lines[1], qr/"kind":"job"/,    'kind preserved');

done_testing;
