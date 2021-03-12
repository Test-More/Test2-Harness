use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use Test2::Harness::Util::File::JSONL;
use App::Yath::Tester qw/yath/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

my $out = yath(
    command => 'test',
    args    => [$dir, '--ext=tx'],
    log     => 1,
    exit    => 0,
);

my $log = $out->{log}->name;

yath(
    command => 'times',
    args    => [$log],
    exit    => 0,
    test    => sub {
        my $out = shift;

        like($out->{output}, qr{Total .* Startup .* Events .* Cleanup .* File}m, "Got header");
        like($out->{output}, qr{t/integration/times/pass\.tx}m,                  "Got pass line");
        like($out->{output}, qr{t/integration/times/pass2\.tx}m,                 "Got pass2 line");
        like($out->{output}, qr{TOTAL}m,                                         "Got total line");
    },
);

done_testing;
