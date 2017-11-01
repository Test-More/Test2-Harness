use Test2::Require::AuthorTesting;
use Test2::V0 -target => 'App::Yath::Command::help';

use ok $CLASS;

use Test2::Tools::HarnessTester -yath_script => 'scripts/yath', qw/make_example_dir run_yath_command/;

# This section is just to make sure that it is possible to run the command. We
# do not actually care about the output much. This is to prevent a release from
# making a command simply die.

my $out = run_yath_command($CLASS->name);
is($out->{exit}, 0, "Exit Success");
like($out->{stdout}, qr/Available Commands/, "Expected output");
ok(!$out->{stderr}, "no stderr");

$out = run_yath_command($CLASS->name, 'test');
is($out->{exit}, 0, "Exit Success");
like($out->{stdout}, qr{Usage: .*yath test}, "Expected output");
ok(!$out->{stderr}, "no stderr");

done_testing;
