use strict;
use warnings;

use Test2::V0;

use Cwd qw/getcwd realpath/;
use File::Spec;
use File::Temp qw/tempdir/;
use Config;

my $yath   = File::Spec->rel2abs('scripts/yath');
my $libdir = File::Spec->rel2abs('lib');
my $perl   = $Config{perlpath};

# The yath script searches upward for .yath.v#.rc to determine which V#
# module to load. During cpanm installs no RC file exists, so we create one
# in a temp dir and run yath from there.
my $dir = tempdir(CLEANUP => 1);
open(my $rc, '>', File::Spec->catfile($dir, '.yath.v0.rc')) or die "Cannot write .yath.v0.rc: $!";
close($rc);

my $can_symlink = do {
    my $td = tempdir(CLEANUP => 1);
    my $src = File::Spec->catfile($td, 'src');
    open(my $fh, '>', $src) or die "Cannot create $src: $!";
    close($fh);
    my $dst = File::Spec->catfile($td, 'dst');
    eval { symlink($src, $dst); 1 } && -l $dst;
};

# All invocations pre-set PERL_HASH_SEED to avoid re-exec
local $ENV{PERL_HASH_SEED} = '20200101';

sub run_yath_in {
    my ($d, @args) = @_;

    # Avoid shell `cd $d &&` because cmd.exe `cd` will not switch drives,
    # which silently leaves cwd on the wrong drive when TEMP is on a
    # different drive than the build directory.
    my $cmd = join ' ', $perl, "-I$libdir", $yath, @args;
    my $cwd = getcwd();
    chdir $d or die "Cannot chdir to $d: $!";
    my $output = `$cmd 2>&1`;
    my $exit   = $? >> 8;
    chdir $cwd or die "Cannot chdir back to $cwd: $!";

    return ($output, $exit);
}

sub run_yath { run_yath_in($dir, @_) }

subtest 'basic invocation with --begin and runtime args' => sub {
    my ($output, $exit) = run_yath('--begin', 'hello', '--begin', 'world', 'foo', 'bar');

    like($output, qr/^Warning:.*Version '0'/m, 'V0 warning is printed');
    like($output, qr/^BEGIN: hello$/m,          'first --begin arg echoed');
    like($output, qr/^BEGIN: world$/m,          'second --begin arg echoed');
    like($output, qr/^RUNTIME: foo$/m,          'first runtime arg echoed');
    like($output, qr/^RUNTIME: bar$/m,          'second runtime arg echoed');

    is($exit, 0, 'exit code is 0');
};

subtest 'no arguments' => sub {
    my ($output, $exit) = run_yath();

    like($output, qr/^Warning:.*Version '0'/m, 'V0 warning is printed');
    unlike($output, qr/^BEGIN: /m,              'no BEGIN output');
    unlike($output, qr/^RUNTIME: /m,            'no RUNTIME output');

    is($exit, 0, 'exit code is 0');
};

subtest 'only --begin args, no runtime args' => sub {
    my ($output, $exit) = run_yath('--begin', 'only');

    like($output, qr/^BEGIN: only$/m,  'begin arg echoed');
    unlike($output, qr/^RUNTIME: /m,   'no RUNTIME output');

    is($exit, 0, 'exit code is 0');
};

subtest 'only runtime args, no --begin' => sub {
    my ($output, $exit) = run_yath('alpha', 'beta');

    unlike($output, qr/^BEGIN: /m,         'no BEGIN output');
    like($output, qr/^RUNTIME: alpha$/m,   'first runtime arg echoed');
    like($output, qr/^RUNTIME: beta$/m,    'second runtime arg echoed');

    is($exit, 0, 'exit code is 0');
};

subtest 'argument ordering is preserved' => sub {
    my ($output, $exit) = run_yath('--begin', 'b1', 'r1', '--begin', 'b2', 'r2');

    # Extract BEGIN and RUNTIME lines in order
    my @begin   = ($output =~ /^BEGIN: (.+)$/mg);
    my @runtime = ($output =~ /^RUNTIME: (.+)$/mg);

    is(\@begin,   ['b1', 'b2'], 'BEGIN args in order');
    is(\@runtime, ['r1', 'r2'], 'RUNTIME args in order');

    is($exit, 0, 'exit code is 0');
};

subtest 'PERL_HASH_SEED re-exec preserves @INC' => sub {
    # Run without PERL_HASH_SEED to trigger re-exec path
    local $ENV{PERL_HASH_SEED};
    delete $ENV{PERL_HASH_SEED};

    my ($output, $exit) = run_yath('--begin', 'reexec', 'test');

    like($output, qr/PERL_HASH_SEED not set/, 'seed message printed');
    like($output, qr/^BEGIN: reexec$/m,        'begin arg survived re-exec');
    like($output, qr/^RUNTIME: test$/m,        'runtime arg survived re-exec');

    is($exit, 0, 'exit code is 0');
};

subtest 'V# as first argument selects version' => sub {
    # Create a dir with a .yath.v0.rc so V0 is available via filename
    my $tdir = tempdir(CLEANUP => 1);
    open(my $fh, '>', File::Spec->catfile($tdir, '.yath.v0.rc')) or die $!;
    close($fh);

    my $cmd = join ' ', "cd", $tdir, "&&", $perl, "-I$libdir", $yath, 'V0', 'hello';
    my $output = `$cmd 2>&1`;
    my $exit   = $? >> 8;

    like($output, qr/^Warning:.*Version '0'/m, 'V0 warning printed when V0 given on CLI');
    like($output, qr/^RUNTIME: hello$/m,       'V0 is not treated as a runtime arg');
    unlike($output, qr/^RUNTIME: V0$/m,        'V0 was stripped from args');

    is($exit, 0, 'exit code is 0');
};

subtest 'v# (lowercase) as first argument selects version' => sub {
    my $tdir = tempdir(CLEANUP => 1);
    open(my $fh, '>', File::Spec->catfile($tdir, '.yath.v0.rc')) or die $!;
    close($fh);

    my $cmd = join ' ', "cd", $tdir, "&&", $perl, "-I$libdir", $yath, 'v0', 'world';
    my $output = `$cmd 2>&1`;
    my $exit   = $? >> 8;

    like($output, qr/^Warning:.*Version '0'/m, 'V0 warning with lowercase v0');
    like($output, qr/^RUNTIME: world$/m,       'runtime arg passed through');
    unlike($output, qr/^RUNTIME: v0$/m,        'v0 was stripped from args');

    is($exit, 0, 'exit code is 0');
};

subtest 'V# CLI overrides rc file version' => sub {
    # Dir has a .yath.v0.rc but no plain .yath.rc or other versioned file
    # Passing V0 explicitly should still use V0 and find the rc file
    my $tdir = tempdir(CLEANUP => 1);
    open(my $fh, '>', File::Spec->catfile($tdir, '.yath.v0.rc')) or die $!;
    close($fh);

    my $cmd = join ' ', "cd", $tdir, "&&", $perl, "-I$libdir", $yath, 'V0', '--begin', 'cli_ver';
    my $output = `$cmd 2>&1`;
    my $exit   = $? >> 8;

    like($output, qr/^Warning:.*Version '0'/m, 'loaded V0 as requested');
    like($output, qr/^BEGIN: cli_ver$/m,        'begin arg processed');

    is($exit, 0, 'exit code is 0');
};

subtest 'V# only matches as first argument' => sub {
    # V0 as second arg should be treated as a runtime arg, not a version selector
    my ($output, $exit) = run_yath('first', 'V0');

    like($output, qr/^RUNTIME: first$/m, 'first arg is runtime');
    like($output, qr/^RUNTIME: V0$/m,    'V0 as second arg is passed through as runtime arg');

    is($exit, 0, 'exit code is 0');
};

subtest 'symlink .yath.rc -> .yath.v0.rc is found' => sub {
    skip_all "symlink not supported on this platform" unless $can_symlink;

    my $tdir = tempdir(CLEANUP => 1);

    # Create versioned file and symlink
    open(my $fh, '>', File::Spec->catfile($tdir, '.yath.v0.rc')) or die $!;
    close($fh);
    symlink('.yath.v0.rc', File::Spec->catfile($tdir, '.yath.rc'))
        or die "Cannot create symlink: $!";

    my ($output, $exit) = run_yath_in($tdir, 'test_arg');

    like($output, qr/^Warning:.*Version '0'/m, 'symlinked .yath.rc resolved to V0');
    like($output, qr/^RUNTIME: test_arg$/m,    'runtime arg processed');

    is($exit, 0, 'exit code is 0');
};

subtest 'uppercase V in rc filename' => sub {
    my $tdir = tempdir(CLEANUP => 1);
    open(my $fh, '>', File::Spec->catfile($tdir, '.yath.V0.rc')) or die $!;
    close($fh);

    my ($output, $exit) = run_yath_in($tdir, 'test_upper');

    like($output, qr/^Warning:.*Version '0'/m, 'V0 loaded from .yath.V0.rc');
    like($output, qr/^RUNTIME: test_upper$/m,  'runtime arg processed');

    is($exit, 0, 'exit code is 0');
};

subtest 'CLI V# finds uppercase V rc filename' => sub {
    my $tdir = tempdir(CLEANUP => 1);
    open(my $fh, '>', File::Spec->catfile($tdir, '.yath.V0.rc')) or die $!;
    close($fh);

    my ($output, $exit) = run_yath_in($tdir, 'V0', 'cli_upper');

    like($output, qr/^Warning:.*Version '0'/m, 'CLI V0 found .yath.V0.rc');
    like($output, qr/^RUNTIME: cli_upper$/m,   'runtime arg processed');

    is($exit, 0, 'exit code is 0');
};

done_testing;
