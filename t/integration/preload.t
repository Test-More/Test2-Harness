use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util::JSON qw/decode_json/;

use Test2::Util qw/CAN_REALLY_FORK/;

skip_all "Cannot fork, skipping preload test"
    unless CAN_REALLY_FORK;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;

my $out = yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-A', '-PTestSimplePreload', '-PTestPreload'],
);

ok(!$out->{exit}, "Exited success");

done_testing;
