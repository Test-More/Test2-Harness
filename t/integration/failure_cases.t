use Test2::V0;
# HARNESS-DURATION-LONG

use App::Yath::Tester qw/yath/;
use File::Spec;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# Timeouts short enough that the failing run does not sit out the default
# ones. These apply to the failing run only: the passing run has nothing to
# wait for, and a slow or loaded machine can easily take longer than 2 seconds
# to get a test started, which would kill a test that was going to pass.
my %CUSTOM = (
    "timeout.tx"           => ['--et',  2],
    "post_exit_timeout.tx" => ['--pet', 2],
    "noplan.tx"            => ['--pet', 2],
);

opendir(my $DH, $dir) or die "Could not open directory $dir: $!";
my @files = sort grep { -f File::Spec->canonpath("$dir/$_") } readdir($DH);
closedir($DH);

my @plain = grep { !$CUSTOM{$_} } @files;

sub path_for { File::Spec->canonpath("$dir/$_[0]") }

# One run for every fixture that needs no special handling, rather than one
# run per fixture: starting yath costs far more than the assertions do. Each
# file is checked by name in the output, which is more than the per-file runs
# asserted -- they only looked at the exit code, which any one failure sets.
yath(
    command => 'test',
    args    => ['-j4', map { path_for($_) } @plain],
    env     => {FAILURE_DO_PASS => 0},
    exit    => T(),
    test    => sub {
        my $out = shift;
        like($out->{output}, qr{FAILED.*\Q$_\E}, "$_ failed") for @plain;
    },
);

# These three have to wait out a timeout, and the option that shortens it is
# global, so they keep a run each rather than imposing one file's timeout on
# another's failure mode.
for my $file (sort keys %CUSTOM) {
    yath(
        command => 'test',
        args    => [@{$CUSTOM{$file}}, path_for($file)],
        env     => {FAILURE_DO_PASS => 0},
        exit    => T(),
        test    => sub {
            my $out = shift;
            like($out->{output}, qr{FAILED.*\Q$file\E}, "$file failed");
        },
    );
}

# Every fixture passes when told to, including the three above: with nothing
# to wait for they need no custom timeouts.
yath(
    command => 'test',
    args    => ['-j4', map { path_for($_) } @files],
    env     => {FAILURE_DO_PASS => 1},
    exit    => F(),
);

done_testing;
