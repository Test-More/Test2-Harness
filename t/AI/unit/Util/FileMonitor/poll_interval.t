use Test2::V0;
use File::Temp qw/tempfile/;

use Test2::Harness2::Util::FileMonitor;

my $CLASS = 'Test2::Harness2::Util::FileMonitor';

my ($fh, $path) = tempfile(UNLINK => 1);
print $fh "x";
close $fh;

# Default interval is 0.05s.
my $m = $CLASS->new(file => $path);
is($m->poll_interval, 0.05, 'default poll_interval is 0.05s');

# Custom interval is stored correctly.
my $m2 = $CLASS->new(file => $path, poll_interval => 0.5);
is($m2->poll_interval, 0.5, 'custom poll_interval stored');

# Static mode also accepts poll_interval (the attribute is always present).
my $m3 = $CLASS->new(static => 1, poll_interval => 0.25);
is($m3->poll_interval, 0.25, 'static mode accepts poll_interval');

# Default is preserved when poll_interval is not supplied (not undef-stomped).
my $m4 = $CLASS->new(file => $path);
is($m4->poll_interval, 0.05, 'second construction also gets default 0.05s');

done_testing;
