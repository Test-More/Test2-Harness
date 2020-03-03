use Test2::V0;

use Config qw/%Config/;
use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util       qw/clean_path/;
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


note q[Checking --exclude-file option when a file is provided on the command line];

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
    note q[Testsuite using symlinks: check that $0 is preserved];

    my $sdir = $dir . '-symlinks';
    my $base    = "$sdir/_base.xt";
    my $symlink = "$sdir/symlink_to_base.xt";

    unlink $symlink if -e $symlink;
    if ( eval{ symlink('_base.xt', $symlink) } ) {

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

{
    note q[Testsuite checking broken symlinks #103];

    my $sdir = $dir . '-broken-symlinks';
    my $symlink = "$sdir/broken-symlink.tx";

    unlink $symlink if -e $symlink;
    if ( eval{ symlink('nothing-there', $symlink) } ) {

        yath(
            command => 'test',
            args => [$sdir, '--ext=tx' ],
            exit => 0,
            test => sub {
                my $out = shift;

                unlike($out->{output}, qr{FAILED}, q[no failures]);
                unlike($out->{output}, qr{\Qbroken-symlink.tx\E}, q[no mention of broken-symlink.tx] );
                like($out->{output}, qr{PASSED.*\Qt/integration/test-broken-symlinks/pass.tx\E}, q[t/integration/test-broken-symlinks/pass.tx PASSED]);
            },
        );
    }
}

{
    note "Testing durations when provided using a json file";

    my $sdir = $dir . '-durations';

    # using a directory
    yath(
        command => 'test',
        args => [ '-v', '-j1', '--durations', "$sdir/../test-durations.json", '--ext=tx', $sdir, ],
        exit => 0,
        test => sub {
            my $out = shift;

            my @lines = sort {
                my ($aj) = ($a =~ m/job\s+(\d+)/) or return 0;
                my ($bj) = ($b =~ m/job\s+(\d+)/) or return 0;
                return $aj <=> $bj;
            } grep { m/\Q( PASSED )\E/ } split /\n/, $out->{output};

            is \@lines, array {

                item match qr{\Qslow-01.tx\E};
                item match qr{\Qslow-02.tx\E};
                item match qr{\Qfast-01.tx\E};
                item match qr{\Qfast-02.tx\E};
                item match qr{\Qfast-03.tx\E};
                item match qr{\Qfast-04.tx\E};

                end;
            }, "tests are run in order from slow to fast - using a directory";
        },
    );

    # using a list of files
    my @files = (
            "$sdir/fast-01.tx", "$sdir/fast-02.tx", "$sdir/fast-03.tx", "$sdir/fast-04.tx",
            "$sdir/slow-01.tx", "$sdir/slow-02.tx"
    );
    my %hfiles = map { $_ => 1 } @files;
    yath(
        command => 'test',
        args => [ '-v', '-j1', '--durations', "$sdir/../test-durations.json", '--ext=tx',
            keys %hfiles, # random order
        ],
        exit => 0,
        test => sub {
            my $out = shift;

            my @lines = sort {
                my ($aj) = ($a =~ m/job\s+(\d+)/) or return 0;
                my ($bj) = ($b =~ m/job\s+(\d+)/) or return 0;
                return $aj <=> $bj;
            } grep { m/\Q( PASSED )\E/ } split /\n/, $out->{output};

            is \@lines, array {

                item match qr{\Qslow-01.tx\E};
                item match qr{\Qslow-02.tx\E};
                item match qr{\Qfast-01.tx\E};
                item match qr{\Qfast-02.tx\E};
                item match qr{\Qfast-03.tx\E};
                item match qr{\Qfast-04.tx\E};

                end;
            }, "tests are run in order from slow to fast - using a list of files";
        },
    );
}

if ("$]" >= 5.026) {
    note q[Checking %INC and @INC setup];

    local @INC =  map { clean_path( $_ ) } grep { $_ ne '.' } @INC;
    local $ENV{PERL5LIB} = join $Config{path_sep}, map { clean_path( $_ ) } grep { $_ ne '.' } split( $Config{path_sep}, $ENV{PERL5LIB} );
    local $ENV{PERL_USE_UNSAFE_INC};
    delete $ENV{PERL_USE_UNSAFE_INC};

    my $sdir = $dir . '-inc';

    yath(
        command => 'test',
        args => ['--ext=tx', '--no-unsafe-inc', $sdir],
        exit => 0,
        test => sub {
            my $out = shift;

            unlike($out->{output}, qr{FAILED}, q[no failures]);
        },
    );
}

done_testing;
