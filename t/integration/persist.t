use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util::JSON qw/decode_json/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;

my $out = yath(command => 'start');
ok(!$out->{exit}, "Started");

$out = yath(command => 'run', args => [$dir, '--ext=tx', '--ext=txx']);
ok($out->{exit}, "Exited failure");
like($out->{output}, qr{FAILED.*fail\.tx}, "'fail.tx' was seen as a failure when reading the output");
like($out->{output}, qr{PASSED.*pass\.tx}, "'pass.tx' was not seen as a failure when reading the output");

$out = yath(command => 'run', args => [$dir, '--ext=tx']);
ok(!$out->{exit}, "Exited success");
unlike($out->{output}, qr{fail\.tx}, "'fail.tx' was not seen when reading the output");
like($out->{output}, qr{PASSED.*pass\.tx}, "'pass.tx' was not seen as a failure when reading the output");

$out = yath(command => 'which');
ok(!$out->{exit}, "'which' exited with success");
like($out->{output}, qr/^\s*Found: .*\.yath-persist\.json$/m, "Found the persist file");
like($out->{output}, qr/^\s*PID: /m, "Found the PID");
like($out->{output}, qr/^\s*Dir: /m, "Found the Dir");

$out = yath(command => 'reload');
ok(!$out->{exit}, "Reload sent");

$out = yath(command => 'watch', args => ['STOP']);
ok(!$out->{exit}, "watch exited with success");
like($out->{output}, qr{yath-nested-runner .* \(default\) Runner caught SIGHUP, reloading}, "Reloaded runner");

$out = yath(command => 'run', args => [$dir, '--ext=txx']);
ok($out->{exit}, "Exited failure");
like($out->{output}, qr{FAILED.*fail\.tx}, "'fail.tx' was seen as a failure when reading the output");
unlike($out->{output}, qr{pass\.tx}, "'pass.tx' was not seen when reading the output");

$out = yath(command => 'run', args => [$dir, '-vvv']);
ok($out->{exit}, "Error if no tests were run");
like($out->{output}, qr/No tests were seen!/, "Got error message");

$out = yath(command => 'stop');
ok(!$out->{exit}, "Stopped");

$out = yath(command => 'which');
ok(!$out->{exit}, "'which' exited with failure");
like($out->{output}, qr/No persistent harness was found for the current path\./, "No active runner");

done_testing;
