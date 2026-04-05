use strict;
use warnings;

use Test2::V0;

use Cwd qw/getcwd realpath/;
use File::Spec;
use Config;

my $yath   = File::Spec->rel2abs('scripts/yath');
my $libdir = File::Spec->rel2abs('lib');
my $perl   = $Config{perlpath};

# All invocations pre-set PERL_HASH_SEED to avoid re-exec
local $ENV{PERL_HASH_SEED} = '20200101';

sub run_yath {
    my (@args) = @_;

    my $cmd = join ' ', $perl, "-I$libdir", $yath, @args;
    my $output = `$cmd 2>&1`;
    my $exit   = $? >> 8;

    return ($output, $exit);
}

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

    my $cmd = join ' ', $perl, "-I$libdir", $yath, '--begin', 'reexec', 'test';
    my $output = `$cmd 2>&1`;
    my $exit   = $? >> 8;

    like($output, qr/PERL_HASH_SEED not set/, 'seed message printed');
    like($output, qr/^BEGIN: reexec$/m,        'begin arg survived re-exec');
    like($output, qr/^RUNTIME: test$/m,        'runtime arg survived re-exec');

    is($exit, 0, 'exit code is 0');
};

done_testing;
