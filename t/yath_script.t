#!/usr/bin/perl
# HARNESS-NO-FORK

use strict;
use warnings;

use Carp::Always;

my %ORIG_INC = (%INC);

@ARGV = ();

my $in_section;
my %sections;

{
    local $.;
    my ($script) = grep { -f $_ } 'scripts/yath', '../scripts/yath';
    die "Could not find yath script" unless $script;
    open(my $fh, '<', $script) or die "Could not open yath script: $!";

    my ($tdir) = grep { -d $_ } 't/yath_script', 'yath_script';
    die "Could not find the t/yath_script directory" unless $tdir;
    chdir("$tdir/nested") or die "Could not change directory: $!";

    while (my $line = <$fh>) {
        die "$script uses $1, it should not" if $line =~ m/^\s*use (strict|warnings)\b.*$/;
        chomp($line);
        if ($line =~ m/^\s*# ==START TESTABLE CODE (\S+)==\s*$/) {
            $in_section = $1;
            push @{$sections{lc($in_section)}} => ("use strict;", "use warnings FATAL => 'all';", "#line " . ($. + 1) . ' "' . $script . '"');
            next;
        }
        if ($line =~ m/^\s*# ==END TESTABLE CODE\s?(\S+)==\s*$/) {
            die "In section '$in_section' but found end of section '$1'" unless $1 eq $in_section;
            $sections{lc($in_section)} = join "\n" => @{delete $sections{lc($in_section)}};
            $in_section = undef;
        }

        next unless $in_section;
        push @{$sections{lc($in_section)}} => $line;
    }
}

my @RESULTS;

sub is($$;$)   { push @RESULTS => ['is',   [@_], [caller()]] }
sub like($$;$) { push @RESULTS => ['like', [@_], [caller()]] }
sub ok($;$)    { push @RESULTS => ['ok',   [@_], [caller()]] }

test_find_config_files();
sub test_find_config_files {
    my ($config, $user_config);
    eval delete($sections{find_config_files}) . <<'    EOT' or confess $@;
        $config = $config_file;
        $user_config = $user_config_file;
        1;
    EOT

    is($config, './../.yath.rc', "Found .yath.rc in a higher dir");
    is($user_config, './.yath.user.rc', "Found .yath.user.rc in the current dir");
}

test_parse_config_files();
sub test_parse_config_files {
    my ($config_args, $to_clean);
    my $code = delete $sections{parse_config_files};

    local @ARGV = ('START', 'END');
    my %CONFIG;

    eval <<"    EOT" or die $@;
        my \$config_file      = './../.yath.rc';
        my \$user_config_file = './.yath.user.rc';
$code
        \$config_args = \\\@CONFIG_ARGS;
        \$to_clean    = \\\@TO_CLEAN;
        1;
    EOT

    is(
        $config_args,
        [
            '-Dpre_lib',
            '-D=./../pre/xxx/lib',
            '-D=./../pre/yyy/lib',
            '-pXXX',
            '-p' => 'YYY',
            '-D=SPLIT',
            '-Dpre_user_lib',
            '-D=./pre/xxx/user/lib',
            '-D=./pre/yyy/user/lib',
            '-pUSER_XXX',
            '-p' => 'USER_YYY',
        ],
        "Got pre-args from all config files"
    );

    is(
        [@ARGV],
        [
            '-Dpre_lib',
            '-D=./../pre/xxx/lib',
            '-D=./../pre/yyy/lib',
            '-pXXX',
            '-p' => 'YYY',
            '-D=SPLIT',
            '-Dpre_user_lib',
            '-D=./pre/xxx/user/lib',
            '-D=./pre/yyy/user/lib',
            '-pUSER_XXX',
            '-p' => 'USER_YYY',
            'START',
            'END',
        ],
        "Prepended args to \@ARGV"
    );

    is(
        {%CONFIG},
        {
            test => [
                '-Itest_lib',
                '-I=./../test/xxx/lib',
                '-I' => './../test/yyy/lib',
                '-xxxx',
                'foo',
                'bar',
                'baz' => 'bat',
                '-Itest_user_lib',
                '-I=./test/xxx/user/lib',
                '-I' => './test/yyy/user/lib',
                '-user_xxxx',
                'user_foo',
                'user_bar',
                'user_baz' => 'user_bat',
            ],
            run => [
                '-Irun_lib',
                '-I=./../run/xxx/lib',
                '-I' => './../run/yyy/lib',
                '-xxxx',
                'foo',
                'bar',
                '-Irun_user_lib',
                '-I=./run/xxx/user/lib',
                '-I' => './run/yyy/user/lib',
                '-user_xxxx',
                'user_foo',
                'user_bar',
            ],
        },
        "Parsed all command args properly"
    );

    is(
        $to_clean,
        [
            ['test', 1, '-I', '=', './../test/xxx/lib'],
            ['test', 3, '-I', ' ', './../test/yyy/lib'],

            ['run', 1, '-I', '=', './../run/xxx/lib'],
            ['run', 3, '-I', ' ', './../run/yyy/lib'],

            ['test', 10, '-I', '=', './test/xxx/user/lib'],
            ['test', 12, '-I', ' ', './test/yyy/user/lib'],

            ['run', 8, '-I', '=', './run/xxx/user/lib'],
            ['run', 10, '-I', ' ', './run/yyy/user/lib'],
        ],
        "Will come back and clean these later"
    );
}

test_pre_parse_d_args();
sub test_pre_parse_d_args {
    my $code = delete $sections{pre_parse_d_args};

    local @INC = ('START', 'END');
    local @ARGV = ('START', '-D=aaa', '-Dbbb', '--no-dev-lib', '-D', '--dev-lib', '-Dxxx', '-Dxxx', '--dev-lib=foo', '-Dbbb', '::', '-Doops', 'END');
    my @DEVLIBS;

    my ($libs, $done);
    eval $code . <<'    EOT' or die $@;
        $libs = \@libs;
        $done = \%done;
        1;
    EOT

    is(
        [@ARGV],
        ['START', '::', '-Doops', 'END'],
        "Modified \@ARGV"
    );

    is(
        $libs,
        ['lib', 't/lib', 'blib/lib', 'blib/arch', 'xxx', 'foo', 'bbb'],
        "Got expected libs"
    );

    is(
        [@DEVLIBS],
        ['lib', 't/lib', 'blib/lib', 'blib/arch', 'xxx', 'foo', 'bbb'],
        "Got expected devlibs"
    );

    is(
        [@INC],
        ['lib', 't/lib', 'blib/lib', 'blib/arch', 'xxx', 'foo', 'bbb', 'START', 'END'],
        "prepended libs to \@INC"
    );

    is(
        $done,
        {
            'lib' => 2,
            't/lib' => 2,
            'blib/lib' => 2,
            'blib/arch' => 2,
            'xxx' => 2,
            'foo' => 1,
            'bbb' => 1,
        },
        "Saw each arg as many times as we expected (including the reset mid-way wiping previously seen out)"
    );

    local @INC = ('START', 'END');
    local @ARGV = ('START', '-Dbbb', '--', '-Doops', 'END');
    @DEVLIBS = ();

    eval $code . <<'    EOT' or die $@;
        $libs = \@libs;
        $done = \%done;
        1;
    EOT

    is(
        [@ARGV],
        ['START', '--', '-Doops', 'END'],
        "Modified \@ARGV"
    );

    is(
        $libs,
        ['bbb'],
        "Got expected libs"
    );

    is(
        [@INC],
        ['bbb', 'START', 'END'],
        "prepended libs to \@INC"
    );

    is(
        $done,
        {
            'bbb' => 1,
        },
        "Saw each arg as many times as we expected"
    );
}

is({%INC}, {%ORIG_INC}, "Did not load anything.");
require Test2::V0;

for my $res (@RESULTS) {
    my ($func, $args, $caller) = @$res;

    my $sub = Test2::V0->can($func) or die "No such test function: $func at $caller->[1] line $caller->[2]\n";

    $sub->(@$args) or warn "Actual assertion at $caller->[1] line $caller->[2]\n";
}

test_cleanup_paths();
sub test_cleanup_paths {
    my $code = delete $sections{cleanup_paths};

    require Cwd;
    require File::Spec;

    my @libs = ('../../lib', './', '../');
    my @DEVLIBS = @libs;
    local @INC = (@libs, 'START', 'END');
    my %CONFIG = (
        test => [
            '-I' => '../../lib',
            '-I=../../lib',
        ],
    );

    my @TO_CLEAN = (
        ['test', 1, '-I', ' ', '../../lib'],
        ['test', 2, '-I', '=', '../../lib'],
    );

    eval $code . "\n1;" or die $@;

    Test2::V0::is(
        \@INC,
        [(map { Cwd::realpath($_) } @libs), 'START', 'END'],
        "Cleaned up \@INC"
    );

    Test2::V0::is(
        \@DEVLIBS,
        [(map { Cwd::realpath($_) } @libs)],
        "Cleaned up \@DEVLIBS"
    );

    Test2::V0::is(
        \%CONFIG,
        {
            test => [
                '-I' => Cwd::realpath('../../lib'),
                '-I=' . Cwd::realpath('../../lib'),
            ],
        },
        "Cleaned up \%CONFIG"
    );
}

test_exec();
sub test_exec {
    no warnings 'once';
    my $code = delete $sections{exec};

    my @ORIG_ARGV = ('-xyz');
    my $SCRIPT;
    my ($exec, $die, @warn);
    my $maybe_exec = '-D';

    my $res;
    {
        local *CORE::GLOBAL::exec = sub { $exec = [@_] };
        local $SIG{__WARN__} = sub { push @warn => @_ };

        $res = eval $code . "\n1;";
        $die = $res ? $@ : undef;
    }

    Test2::V0::ok($SCRIPT, "Set SCRIPT");
    Test2::V0::ok(-e $SCRIPT, "Valid path for script");
    Test2::V0::ok(!$exec, "Did not exec");
    Test2::V0::ok(!$die, "Did not die");
    Test2::V0::ok(!@warn, "Did not warn");

    $code =~ s/#line (\d+) ".*"/#line $1 "old_yath"/;

    {
        local *CORE::GLOBAL::exec = sub { $exec = [@_]; 1 };
        local $SIG{__WARN__} = sub { push @warn => @_ };

        $res = eval $code . "\n1;";
        $die = $res ? undef : $@;
    }

    Test2::V0::like($SCRIPT, qr/old_yath$/, "Initial script is old");
    Test2::V0::like($exec, [qr{scripts/yath$}, '-xyz'], "exec called new yath");
    Test2::V0::like($die, qr/Should not see this, exec failed/, "Died when exec failed");
    Test2::V0::like(\@warn, [qr{-D was used, and scripts/yath is present, using exec to switch to it\.}], "Warned about the exec");
}

die "The following sections were not tested: " . join(', ', keys %sections)
    if keys %sections;

Test2::V0::done_testing();
