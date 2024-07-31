use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Util qw/find_yath/;
find_yath();    # cache result before we chdir

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util::JSON qw/decode_json/;

use Test2::Plugin::Immiscible(sub { $ENV{TEST2_HARNESS_ACTIVE} ? 1 : 0 });

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

my $out;

yath(
    command => 'projects',
    args    => ['--ext=tx', '--', $dir],
    exit    => 0,
    test    => sub {
        my $out = shift;

        like($out->{output}, qr{PASSED .*foo.*t.*pass\.tx}, "Found pass.tx in foo project");
        like($out->{output}, qr{PASSED .*bar.*t.*pass\.tx}, "Found pass.tx in bar project");
        like($out->{output}, qr{PASSED .*baz.*t.*pass\.tx}, "Found pass.tx in baz project");
        unlike($out->{output}, qr{fail\.txx}, "Did not run fail.txx");
    },
);

yath(
    command => 'projects',
    args    => ['--ext=tx', '--ext=txx', '--', $dir],
    exit    => T(),
    test    => sub {
        my $out = shift;
        like($out->{output}, qr{PASSED .*foo.*t.*pass\.tx},  "Found pass.tx in foo project");
        like($out->{output}, qr{PASSED .*bar.*t.*pass\.tx},  "Found pass.tx in bar project");
        like($out->{output}, qr{PASSED .*baz.*t.*pass\.tx},  "Found pass.tx in baz project");
        like($out->{output}, qr{FAILED .*baz.*t.*fail\.txx}, "ran fail.txx");
    },
);

chdir($dir);

yath(
    command => 'projects',
    args    => ['--ext=tx', '-v'],
    exit    => 0,
    test    => sub {
        my $out = shift;

        like($out->{output}, qr{PASSED .*foo.*t.*pass\.tx}, "Found pass.tx in foo project");
        like($out->{output}, qr{PASSED .*bar.*t.*pass\.tx}, "Found pass.tx in bar project");
        like($out->{output}, qr{PASSED .*baz.*t.*pass\.tx}, "Found pass.tx in baz project");
        unlike($out->{output}, qr{fail\.txx}, "Did not run fail.txx");
    },
);

yath(
    command => 'projects',
    args    => ['--ext=tx', '--ext=txx'],
    exit    => T(),
    test    => sub {
        my $out = shift;

        like($out->{output}, qr{PASSED .*foo.*t.*pass\.tx},  "Found pass.tx in foo project");
        like($out->{output}, qr{PASSED .*bar.*t.*pass\.tx},  "Found pass.tx in bar project");
        like($out->{output}, qr{PASSED .*baz.*t.*pass\.tx},  "Found pass.tx in baz project");
        like($out->{output}, qr{FAILED .*baz.*t.*fail\.txx}, "ran fail.txx");
    },
);

done_testing;
