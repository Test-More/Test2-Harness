use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util::JSON qw/decode_json/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;

my $out;

$out = yath(command => 'projects', args => ['--ext=tx', '--', $dir]);
ok(!$out->{exit}, "Passed");
like($out->{output}, qr{PASSED .*foo.*t.*pass\.tx}, "Found pass.tx in foo project");
like($out->{output}, qr{PASSED .*bar.*t.*pass\.tx}, "Found pass.tx in bar project");
like($out->{output}, qr{PASSED .*baz.*t.*pass\.tx}, "Found pass.tx in baz project");
unlike($out->{output}, qr{fail\.txx}, "Did not run fail.txx");

$out = yath(command => 'projects', args => ['--ext=tx', '--ext=txx', '--', $dir]);
ok($out->{exit}, "Failed");
like($out->{output}, qr{PASSED .*foo.*t.*pass\.tx}, "Found pass.tx in foo project");
like($out->{output}, qr{PASSED .*bar.*t.*pass\.tx}, "Found pass.tx in bar project");
like($out->{output}, qr{PASSED .*baz.*t.*pass\.tx}, "Found pass.tx in baz project");
like($out->{output}, qr{FAILED .*baz.*t.*fail\.txx}, "ran fail.txx");

chdir($dir);
$out = yath(command => 'projects', args => ['--ext=tx']);
ok(!$out->{exit}, "Passed");
like($out->{output}, qr{PASSED .*foo.*t.*pass\.tx}, "Found pass.tx in foo project");
like($out->{output}, qr{PASSED .*bar.*t.*pass\.tx}, "Found pass.tx in bar project");
like($out->{output}, qr{PASSED .*baz.*t.*pass\.tx}, "Found pass.tx in baz project");
unlike($out->{output}, qr{fail\.txx}, "Did not run fail.txx");

$out = yath(command => 'projects', args => ['--ext=tx', '--ext=txx']);
ok($out->{exit}, "Failed");
like($out->{output}, qr{PASSED .*foo.*t.*pass\.tx}, "Found pass.tx in foo project");
like($out->{output}, qr{PASSED .*bar.*t.*pass\.tx}, "Found pass.tx in bar project");
like($out->{output}, qr{PASSED .*baz.*t.*pass\.tx}, "Found pass.tx in baz project");
like($out->{output}, qr{FAILED .*baz.*t.*fail\.txx}, "ran fail.txx");

done_testing;
