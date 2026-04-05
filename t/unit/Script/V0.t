use strict;
use warnings;

use Test2::V0;

use App::Yath::Script::V0;

subtest 'do_begin parses --begin args' => sub {
    local @ARGV;
    my $output = '';
    {
        local *STDOUT;
        open(STDOUT, '>', \$output) or die "Cannot redirect STDOUT: $!";
        App::Yath::Script::V0->do_begin(
            argv        => ['--begin', 'hello', '--begin', 'world', 'foo', 'bar'],
            script      => $0,
            config      => undef,
            user_config => undef,
        );
    }

    is($output, "BEGIN: hello\nBEGIN: world\n", 'prints BEGIN args during do_begin');
    is(\@ARGV, ['foo', 'bar'], 'non-option args placed back in @ARGV');
};

subtest 'do_runtime echoes remaining args' => sub {
    local @ARGV = ('baz', 'qux');
    my $output = '';
    my $exit;
    {
        local *STDOUT;
        open(STDOUT, '>', \$output) or die "Cannot redirect STDOUT: $!";
        $exit = App::Yath::Script::V0->do_runtime();
    }

    is($output, "RUNTIME: baz\nRUNTIME: qux\n", 'prints RUNTIME args');
    is($exit, 0, 'returns 0');
};

subtest 'do_begin with no --begin args' => sub {
    local @ARGV;
    my $output = '';
    {
        local *STDOUT;
        open(STDOUT, '>', \$output) or die "Cannot redirect STDOUT: $!";
        App::Yath::Script::V0->do_begin(
            argv        => ['foo', 'bar'],
            script      => $0,
            config      => undef,
            user_config => undef,
        );
    }

    is($output, '', 'no BEGIN output when no --begin args');
    is(\@ARGV, ['foo', 'bar'], 'all args are non-option');
};

subtest 'do_runtime with empty @ARGV' => sub {
    local @ARGV;
    my $output = '';
    my $exit;
    {
        local *STDOUT;
        open(STDOUT, '>', \$output) or die "Cannot redirect STDOUT: $!";
        $exit = App::Yath::Script::V0->do_runtime();
    }

    is($output, '', 'no output with empty @ARGV');
    is($exit, 0, 'returns 0');
};

done_testing;
