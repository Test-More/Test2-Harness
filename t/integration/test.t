use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util::JSON qw/decode_json/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '--ext=txx'],
    exit    => T(),
    test    => sub {
        my $out = shift;

        like($out->{output}, qr{FAILED.*fail\.tx}, "'fail.tx' was seen as a failure when reading the output");
        like($out->{output}, qr{PASSED.*pass\.tx}, "'pass.tx' was not seen as a failure when reading the output");
    },
);

yath(
    command => 'test',
    args    => [$dir, '--ext=tx'],
    exit    => 0,
    test    => sub {
        my $out = shift;
        unlike($out->{output}, qr{FAILED.*fail\.tx}, "'fail.tx' was seen as a failure when reading the output");
        like($out->{output}, qr{PASSED.*pass\.tx}, "'pass.tx' was not seen as a failure when reading the output");
    },
);

yath(
    command => 'test',
    args => [$dir, '--ext=txx'],
    exit => T(),
    test => sub {
        my $out = shift;

        like($out->{output}, qr{FAILED.*fail\.tx}, "'fail.tx' was seen as a failure when reading the output");
        unlike($out->{output}, qr{PASSED.*pass\.tx}, "'pass.tx' was not seen as a failure when reading the output");
    },
);

yath(
    command => 'test',
    args => [$dir, '-vvv'],
    exit => T(),
    test => sub {
        my $out = shift;

        like($out->{output}, qr/No tests were seen!/, "Got error message");
    },
);

yath(
    command => 'test',
    args    => [ "--exclude-file=$dir/fail.txx", "$dir/pass.tx", "$dir/fail.txx" ],
    exit    => 0,
    test    => sub {
        my $out = shift;

        unlike($out->{output}, qr{FAILED.*fail\.tx}, "'fail.tx' was excluded using '--exclude-file' option");
        like($out->{output}, qr{PASSED.*pass\.tx}, "'pass.tx' was not seen as a failure when reading the output");
    },
);

{
    my $sdir = $dir . '-symlinks';
    my $base    = "$sdir/_base.xt";
    my $symlink = "$sdir/symlink_to_base.xt";

    unlink $symlink if -e $symlink;
    if ( eval{ symlink('_base.xt', $symlink); 1 } ) {

        yath(
            command => 'test',
            args => [$sdir, '--ext=xt' ],
            exit => 0,
            test => sub {
                my $out = shift;

                like($out->{output}, qr{SKIPPED.*\Q$base\E}, "'_base.xt' was skipped");
                like($out->{output}, qr{PASSED.*\Q$symlink\E}, "'symlink_to_base.xt' passed [and is not skipped]");
            },
        );

        yath(
            command => 'test',
            args => [ $base, $symlink ],
            exit => 0,
            test => sub {
                my $out = shift;

                like($out->{output}, qr{SKIPPED.*\Q$base\E}, "'_base.xt' was skipped");
                like($out->{output}, qr{PASSED.*\Q$symlink\E}, "'symlink_to_base.xt' passed [and is not skipped]");
            },
        );


    }

}

done_testing;
