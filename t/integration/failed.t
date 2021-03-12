use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util::JSON qw/decode_json/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

yath(
    command => 'test',
    args    => [$dir, '--ext=tx'],
    log     => 1,
    exit    => T(),
    test    => sub {
        my $out     = shift;
        my $logfile = $out->{log}->name;

        $out = yath(
            command => 'failed',
            args    => [$logfile],
            env     => {TABLE_TERM_SIZE => 1000, TS_TERM_SIZE => 1000},
            exit    => 0,
            test    => sub {
                my $out = shift;

                ok(!$out->{exit}, "'failed' command exits true");
                like($out->{output}, qr{fail\.tx}, "'fail.tx' was seen as a failure when reading the log");
                unlike($out->{output}, qr{pass\.tx}, "'pass.tx' was not seen as a failure when reading the log");
            },
        );
    },
);



done_testing;
