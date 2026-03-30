use Test2::V0 -target => 'Test2::Harness::TestSettings';
use Test2::Util qw/IS_WIN32/;

subtest 'constructor with no args' => sub {
    my $ts = $CLASS->new;
    ok($ts->isa($CLASS), 'creates instance with defaults');
};

subtest 'default values' => sub {
    my $ts = $CLASS->new;
    is($ts->event_timeout,     60, 'default event_timeout is 60');
    is($ts->post_exit_timeout, 15, 'default post_exit_timeout is 15');
    is($ts->lib,               1,  'lib defaults to true');
    is($ts->blib,              1,  'blib defaults to true');
    is($ts->allow_retry,       1,  'allow_retry defaults to true');
    is($ts->event_uuids,       1,  'event_uuids defaults to true');
    is($ts->mem_usage,         1,  'mem_usage defaults to true');
    is($ts->use_stream,        1,  'use_stream defaults to true');
    is($ts->use_timeout,       1,  'use_timeout defaults to true');
};

subtest 'includes — lib and blib by default' => sub {
    my $ts = $CLASS->new(lib => 1, blib => 1);
    my $inc = $ts->includes;
    ref_ok($inc, 'ARRAY', 'includes returns arrayref');
    ok(scalar(grep { $_ eq 'lib' } @$inc), 'lib dir included when lib=1');
};

subtest 'includes — tlib' => sub {
    my $ts = $CLASS->new(tlib => 1, lib => 0, blib => 0);
    my $inc = $ts->includes;
    ok(scalar(grep { m/t[\/\\]lib/ } @$inc), 't/lib included when tlib=1');
};

subtest 'use_preload and use_fork disabled on Windows' => sub {
    SKIP: {
        skip 'not on Windows' unless IS_WIN32;
        my $ts = $CLASS->new(use_preload => 1, use_fork => 1);
        is($ts->use_preload, 0, 'use_preload=0 on Windows');
        is($ts->use_fork,    0, 'use_fork=0 on Windows');
    }
};

subtest 'use_preload and use_fork enabled on non-Windows' => sub {
    SKIP: {
        skip 'only on non-Windows' if IS_WIN32;
        my $ts = $CLASS->new(use_preload => 1, use_fork => 1);
        is($ts->use_preload, 1, 'use_preload=1 on non-Windows when set');
        is($ts->use_fork,    1, 'use_fork=1 on non-Windows when set');
    }
};

subtest 'merge — later wins for scalar/bool fields' => sub {
    my $a = $CLASS->new(event_timeout => 30, lib => 0);
    my $b = $CLASS->new(event_timeout => 90, lib => 1);
    my $merged = $CLASS->merge($a, $b);
    is($merged->event_timeout, 90, 'later item wins for event_timeout');
    is($merged->lib,           1,  'later item wins for lib');
};

subtest 'merge — arrays deduplicated' => sub {
    my $a = $CLASS->new(switches => ['-T', '-w']);
    my $b = $CLASS->new(switches => ['-w', '-X']);
    my $merged = $CLASS->merge($a, $b);
    my %seen;
    my @deduped = grep { !$seen{$_}++ } @{$merged->switches};
    is(scalar(@deduped), scalar(@{$merged->switches}), 'no duplicate switches after merge');
    ok(scalar(grep { $_ eq '-T' } @{$merged->switches}), '-T present');
    ok(scalar(grep { $_ eq '-w' } @{$merged->switches}), '-w present');
    ok(scalar(grep { $_ eq '-X' } @{$merged->switches}), '-X present');
};

subtest 'merge — hashes merged' => sub {
    my $a = $CLASS->new(env_vars => {FOO => '1', BAR => '2'});
    my $b = $CLASS->new(env_vars => {BAR => '3', BAZ => '4'});
    my $merged = $CLASS->merge($a, $b);
    is($merged->env_vars->{FOO}, '1', 'FOO from first');
    is($merged->env_vars->{BAR}, '3', 'BAR overridden by second');
    is($merged->env_vars->{BAZ}, '4', 'BAZ from second');
};

subtest 'merge — propagate_false for use_fork and use_preload' => sub {
    SKIP: {
        skip 'only on non-Windows' if IS_WIN32;
        my $permissive = $CLASS->new(use_fork => 1, use_preload => 1);
        my $restrictive = $CLASS->new(use_fork => 0, use_preload => 0);
        my $merged = $CLASS->merge($permissive, $restrictive);
        is($merged->use_fork,    0, 'use_fork=0 propagates through merge');
        is($merged->use_preload, 0, 'use_preload=0 propagates through merge');
    }
};

subtest 'set_env_vars' => sub {
    my $ts = $CLASS->new;
    $ts->set_env_vars(MY_VAR => 'hello', OTHER => 'world');
    is($ts->env_vars->{MY_VAR}, 'hello', 'MY_VAR set');
    is($ts->env_vars->{OTHER},  'world', 'OTHER set');
};

subtest 'TO_JSON includes class' => sub {
    my $ts   = $CLASS->new;
    my $json = $ts->TO_JSON;
    ref_ok($json, 'HASH', 'TO_JSON returns hashref');
    is($json->{class}, $CLASS, 'TO_JSON includes class');
};

subtest 'load_import includes UUID and MemUsage by default' => sub {
    my $ts = $CLASS->new(event_uuids => 1, mem_usage => 1);
    my $li = $ts->load_import;
    ref_ok($li, 'HASH', 'load_import returns hashref');
    ok(scalar(grep { $_ eq 'Test2::Plugin::UUID' } @{$li->{'@'} // []}), 'UUID plugin present');
    ok(scalar(grep { $_ eq 'Test2::Plugin::MemUsage' } @{$li->{'@'} // []}), 'MemUsage plugin present');
};

done_testing;
