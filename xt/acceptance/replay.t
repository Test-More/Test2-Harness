use Test2::Require::AuthorTesting;
use Test2::V0 -target => 'App::Yath::Command::replay';

use Test2::Tools::HarnessTester -yath_script => 'scripts/yath', qw/run_yath_command/;

use ok $CLASS;

my $out = run_yath_command('replay', 't/example_log.jsonl.bz2');
is($out->{exit}, 0, "Success");
like($out->{stdout}, qr/ job\s+$_ /, "Saw job $_") for 1 .. 12;

$out = run_yath_command('replay', 't/example_log.jsonl.bz2', 5, 6);
is($out->{exit}, 0, "Success");
like($out->{stdout}, qr/ job\s+$_ /, "Saw job $_") for 5 .. 6;
unlike($out->{stdout}, qr/ job\s+$_ /, "Ignored job $_") for 1 .. 4, 7 .. 12;

done_testing;
