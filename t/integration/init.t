use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;
use Cwd qw/cwd/;

use App::Yath::Tester qw/yath/;
use App::Yath::Util qw/find_yath/;
find_yath();    # cache result before we chdir

my $orig = cwd();
my $dir = tempdir(CLEANUP => 1);
chdir($dir);

yath(
    command => 'init',
    args    => [],
    exit    => 0,
    test    => sub {
        like($_, qr/Writing test\.pl/, "Short message");

        ok(-e 'test.pl', "Added test.pl");

        open(my $fh, '<', 'test.pl') or die $!;
        my $found = 0;
        while (my $line = <$fh>) {
            next unless $line =~ m/THIS IS A GENERATED YATH RUNNER TEST/;
            $found++;
            last;
        }

        ok($found, "Found generated note");
    },
);

chdir($orig);

done_testing;
