use Test2::V0;

use App::Yath2::Plugin::SysInfo;
use Sys::Hostname qw/hostname/;

subtest 'role composition' => sub {
    ok(App::Yath2::Plugin::SysInfo->DOES('App::Yath2::Role::Plugin'),
        'SysInfo consumes App::Yath2::Role::Plugin');
    ok(App::Yath2::Plugin::SysInfo->DOES('Test2::Harness2::Role::Plugin'),
        'SysInfo also satisfies Test2::Harness2::Role::Plugin transitively');
};

subtest 'run_fields basic shape' => sub {
    my $p = App::Yath2::Plugin::SysInfo->new();
    my @fields = $p->run_fields;
    is(scalar(@fields), 1, 'single field produced');

    my $f = $fields[0];
    is(ref($f), 'HASH', 'field is a hashref');
    is($f->{name}, 'sys', 'field name is "sys"');
    ok(exists $f->{data}, 'has data');
    is(ref($f->{data}), 'HASH', 'data is a hashref');
    ok(exists $f->{data}{env},    'env subkey present');
    ok(exists $f->{data}{ipc},    'ipc subkey present');
    ok(exists $f->{data}{config}, 'config subkey present');

    # IPC keys
    for my $k (qw/can_fork can_really_fork can_thread can_sigsys/) {
        ok(exists $f->{data}{ipc}{$k}, "ipc.$k present");
    }

    # A few of the fixed Config fields we project
    for my $k (qw/version osname archname useithreads useperlio/) {
        ok(exists $f->{data}{config}{$k}, "config.$k present");
    }
};

subtest 'hostname capture' => sub {
    my $p = App::Yath2::Plugin::SysInfo->new();
    my ($f) = $p->run_fields;

    if (my $h = hostname()) {
        is($f->{data}{hostname}, $h, 'hostname stamped');
        is($f->{raw}, $h, 'raw is full hostname');
        ok(length($f->{details}) <= 18 || $f->{details} !~ /\./,
            'short form is truncated to <= 18 chars or is single-segment');
    }
    else {
        is($f->{raw}, 'system info', 'no hostname -> fallback raw');
        is($f->{details}, 'sys', 'no hostname -> fallback short');
    }
};

subtest 'host_short_pattern' => sub {
    my $h = hostname();
    skip_all 'no hostname on this system' unless $h;

    # Use a regex that captures the whole hostname; confirms the
    # pattern arg is consulted and the first capture wins.
    my $p = App::Yath2::Plugin::SysInfo->new(host_short_pattern => '(\w+)');
    my ($f) = $p->run_fields;

    ok($h =~ /^(\w+)/, 'hostname starts with a word-char run');
    my $expected = $1;
    is($f->{details}, $expected, 'short form is the first capture of the pattern');
};

subtest 'env projection filters' => sub {
    local %ENV = %ENV;    # restore after subtest
    $ENV{YATH_TEST_MARKER}  = 'y';
    $ENV{PERL_TEST_MARKER}  = 'p';
    $ENV{UNRELATED_VARIANT} = 'should-not-show';

    my $p = App::Yath2::Plugin::SysInfo->new();
    my ($f) = $p->run_fields;

    is($f->{data}{env}{YATH_TEST_MARKER}, 'y', 'YATH_* env captured');
    is($f->{data}{env}{PERL_TEST_MARKER}, 'p', 'PERL_* env captured');
    ok(!exists $f->{data}{env}{UNRELATED_VARIANT},
        'random env keys are not captured');
};

subtest 'run_queued returns the run field' => sub {
    my $p = App::Yath2::Plugin::SysInfo->new();

    # run_queued receives the Run object; SysInfo doesn't use it,
    # so pass a stub.
    my @out = $p->run_queued({});
    is(scalar(@out), 1, 'run_queued produced one field');
    is($out[0]->{name}, 'sys', 'it is the sys field');
};

done_testing;
