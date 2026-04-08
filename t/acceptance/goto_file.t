use strict;
use warnings;

use Test2::V0;
use Test2::Require::Module 'goto::file';

use Config;
use File::Spec;
use File::Temp qw/tempdir/;

my $yath   = File::Spec->rel2abs('scripts/yath');
my $libdir = File::Spec->rel2abs('lib');
my $perl   = $Config{perlpath};

# The yath script searches upward for .yath.v#.rc to determine which V#
# module to load. During cpanm installs no RC file exists, so we create one
# in a temp dir and run yath from there.
my $dir = tempdir(CLEANUP => 1);
open(my $rc, '>', File::Spec->catfile($dir, '.yath.v0.rc')) or die "Cannot write .yath.v0.rc: $!";
close($rc);

# All invocations pre-set PERL_HASH_SEED to avoid re-exec
local $ENV{PERL_HASH_SEED} = '20200101';

sub run_yath {
    my (@args) = @_;

    my $cmd = join ' ', "cd", $dir, "&&", $perl, "-I$libdir", $yath, @args;
    my $output = `$cmd 2>&1`;
    my $exit   = $? >> 8;

    return ($output, $exit);
}

my $target = File::Spec->catfile($dir, 'target.pl');
open(my $fh, '>', $target) or die "Cannot write $target: $!";
print $fh <<'TARGET';
print "GOTO_TARGET_RAN\n";
exit 0;
TARGET
close($fh);

subtest 'goto::file in do_begin prevents runtime handler' => sub {
    my ($output, $exit) = run_yath('--goto-file', $target, '--begin', 'hello', 'runtime_arg');

    like($output, qr/^BEGIN: hello$/m,          'do_begin ran and processed --begin args');
    like($output, qr/^GOTO_TARGET_RAN$/m,       'goto::file target file executed');
    unlike($output, qr/^RUNTIME: /m,            'do_runtime never ran');

    is($exit, 0, 'exit code is 0');
};

done_testing;
