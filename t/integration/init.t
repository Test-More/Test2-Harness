use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Tester qw/yath/;

my $dir = tempdir(CLEANUP => 1);
chdir($dir);

my $out;

$out = yath(command => 'init', args => []);
ok(!$out->{exit}, "Exit success");
like($out->{output}, qr/Writing test\.pl/, "Short message");

ok(-e 'test.pl', "Added test.pl");

open(my $fh, '<', 'test.pl') or die $!;
my $found = 0;
while (my $line = <$fh>) {
    next unless $line =~ m/THIS IS A GENERATED YATH RUNNER TEST/;
    $found++;
    last;
}

ok($found, "Found generated note");

done_testing;
