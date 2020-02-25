use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util::JSON qw/decode_json/;

skip_all "This test is not run under automated testing"
    if $ENV{AUTOMATED_TESTING};

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;

yath(command => 'start', exit => 0);

yath(
    command => 'run',
    args    => [$dir, '--ext=tx', '--ext=txx'],
    exit    => T(),
    test    => sub {
        my $out = shift;
        like($out->{output}, qr{FAILED.*fail\.tx}, "'fail.tx' was seen as a failure when reading the output");
        like($out->{output}, qr{PASSED.*pass\.tx}, "'pass.tx' was not seen as a failure when reading the output");
    },
);


yath(
    command => 'run',
    args    => [$dir, '--ext=tx'],
    exit    => 0,
    test    => sub {
        my $out = shift;
        unlike($out->{output}, qr{fail\.tx}, "'fail.tx' was not seen when reading the output");
        like($out->{output}, qr{PASSED.*pass\.tx}, "'pass.tx' was not seen as a failure when reading the output");
    },
);

yath(
    command => 'which',
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/^\s*Found: .*yath-persist\.json$/m, "Found the persist file");
        like($out->{output}, qr/^\s*PID: /m,                        "Found the PID");
        like($out->{output}, qr/^\s*Dir: /m,                        "Found the Dir");
    },
);

yath(command => 'reload', exit => 0);

yath(
    command => 'watch',
    args    => ['STOP'],
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr{yath-nested-runner \(default\) Runner caught SIGHUP, reloading}, "Reloaded runner");
    },
);

yath(
    command => 'run',
    args => [$dir, '--ext=txx'],
    exit => T(),
    test => sub {
        my $out = shift;

        like($out->{output}, qr{FAILED.*fail\.tx}, "'fail.tx' was seen as a failure when reading the output");
        unlike($out->{output}, qr{pass\.tx}, "'pass.tx' was not seen when reading the output");
    },
);

yath(
    command => 'run',
    args => [$dir, '-vvv'],
    exit => T(),
    test => sub {
        my $out = shift;

        like($out->{output}, qr/No tests were seen!/, "Got error message");
    },
);

yath(command => 'stop', exit => 0);

yath(
    command => 'which',
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/No persistent harness was found for the current path\./, "No active runner");
    },
);

done_testing;
