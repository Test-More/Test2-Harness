use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util::JSON qw/decode_json/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;

my $out = yath(command => 'test', args => [$dir, '--ext=tx', '--ext=txx']);
ok($out->{exit}, "Exited failure");
like($out->{output}, qr{FAILED.*fail\.tx}, "'fail.tx' was seen as a failure when reading the output");
like($out->{output}, qr{PASSED.*pass\.tx}, "'pass.tx' was not seen as a failure when reading the output");

$out = yath(command => 'test', args => [$dir, '--ext=tx']);
ok(!$out->{exit}, "Exited success");
unlike($out->{output}, qr{FAILED.*fail\.tx}, "'fail.tx' was seen as a failure when reading the output");
like($out->{output}, qr{PASSED.*pass\.tx}, "'pass.tx' was not seen as a failure when reading the output");

$out = yath(command => 'test', args => [$dir, '--ext=txx']);
ok($out->{exit}, "Exited failure");
like($out->{output}, qr{FAILED.*fail\.tx}, "'fail.tx' was seen as a failure when reading the output");
unlike($out->{output}, qr{PASSED.*pass\.tx}, "'pass.tx' was not seen as a failure when reading the output");

$out = yath(command => 'test', args => [$dir, '-vvv']);
ok($out->{exit}, "Error if no tests were run");
like($out->{output}, qr/No tests were seen!/, "Got error message");

done_testing;
