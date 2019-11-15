use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util::JSON qw/decode_json/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;

my $out1 = yath(
    command => 'test',
    args    => [$dir, '--ext=tx'],
    log     => 1,
);

# Strip out log line, and extra newlines
$out1->{output} =~ s/^.*Wrote log file:.*$//m;
$out1->{output} =~ s/\n+/\n/g;

like($out1->{output}, qr{FAILED.*fail\.tx}, "'fail.tx' was seen as a failure when reading the log");
like($out1->{output}, qr{PASSED.*pass\.tx}, "'pass.tx' was not seen as a failure when reading the log");

my $logfile = $out1->{log}->name;

my $out2 = yath(
    command => 'replay',
    args    => [$logfile],
);

# Strip out extra newlines
$out2->{output} =~ s/\n+/\n/g;
is($out2->{output}, $out1->{output}, "Replay has identical output to original");
is($out2->{exit}, $out1->{exit}, "Replay has identical exit");

done_testing;
