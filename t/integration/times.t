use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use Test2::Harness::Util::File::JSONL;
use App::Yath::Tester qw/yath/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;

my $out;

$out = yath(command => 'test', args => [$dir, '--ext=tx'], log => 1);
ok(!$out->{exit}, "Exit success");

my $log = $out->{log}->name;

$out = yath(command => 'times', args => [$log]);
ok(!$out->{exit}, "Exit success");

like($out->{output}, qr{Total .* Startup .* Events .* Cleanup .* File}m, "Got header");
like($out->{output}, qr{t/integration/times/pass\.tx}m,                  "Got pass line");
like($out->{output}, qr{t/integration/times/pass2\.tx}m,                 "Got pass2 line");
like($out->{output}, qr{TOTAL}m,                                         "Got total line");

done_testing;
