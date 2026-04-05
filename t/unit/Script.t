use strict;
use warnings;

use Test2::V0;

use App::Yath::Script qw/clean_path find_in_updir mod2file script module/;
use Cwd qw/realpath getcwd/;
use File::Spec;
use File::Temp qw/tempdir/;

subtest 'mod2file' => sub {
    is(mod2file('App::Yath::Script'),     'App/Yath/Script.pm',     'nested module');
    is(mod2file('Foo'),                   'Foo.pm',                 'single-level module');
    is(mod2file('A::B::C::D'),            'A/B/C/D.pm',             'deeply nested module');

    like(dies { mod2file(undef) }, qr/No module name provided/, 'undef dies');
    like(dies { mod2file('') },   qr/No module name provided/, 'empty string dies');
};

subtest 'clean_path' => sub {
    my $cwd = getcwd();

    like(dies { clean_path(undef) }, qr/No path was provided/, 'undef dies');
    like(dies { clean_path('') },   qr/No path was provided/, 'empty string dies');

    my $result = clean_path('lib');
    ok(-d $result, 'result is a real directory');
    is($result, File::Spec->rel2abs(realpath('lib')), 'resolves to absolute realpath');

    # With absolute=0, skip realpath
    my $no_real = clean_path('lib', 0);
    is($no_real, File::Spec->rel2abs('lib'), 'absolute=0 skips realpath');
};

subtest 'find_in_updir' => sub {
    # Create a temp file in cwd so we have something reliable to find
    my $marker = ".yath_test_marker_$$";
    open(my $fh, '>', $marker) or die "Cannot create $marker: $!";
    close($fh);

    my $found = find_in_updir($marker);
    ok(defined $found, 'found marker file');
    ok(-f $found,      'marker file is a file');
    like($found, qr/\Q$marker\E$/, 'path ends with marker filename');

    unlink $marker;

    # Non-existent file returns undef
    my $missing = find_in_updir('.nonexistent_file_that_should_not_exist');
    is($missing, undef, 'returns undef for missing file');
};

subtest 'script and module accessors' => sub {
    # Before do_begin, these depend on package state. Just verify they are callable.
    ok(defined &App::Yath::Script::script, 'script() is defined');
    ok(defined &App::Yath::Script::module, 'module() is defined');
};

subtest 'inject_includes' => sub {
    local %ENV = %ENV;
    delete $ENV{T2_HARNESS_INCLUDES};

    # Should be a no-op when env var is not set
    my @orig_inc = @INC;
    App::Yath::Script::inject_includes();
    is(\@INC, \@orig_inc, 'no-op without T2_HARNESS_INCLUDES');

    # Should replace @INC when set
    $ENV{T2_HARNESS_INCLUDES} = '/fake/path1;/fake/path2';
    App::Yath::Script::inject_includes();
    is(\@INC, ['/fake/path1', '/fake/path2'], 'replaces @INC from env var');

    # Restore
    @INC = @orig_inc;
};

subtest 'seed_hash' => sub {
    local %ENV = %ENV;

    # When already set, should return 0
    $ENV{PERL_HASH_SEED} = '12345';
    is(App::Yath::Script::seed_hash(), 0, 'returns 0 when PERL_HASH_SEED is set');

    # When not set, should set it and return 1
    delete $ENV{PERL_HASH_SEED};
    my $output = '';
    {
        local *STDOUT;
        open(STDOUT, '>', \$output) or die "Cannot redirect STDOUT: $!";
        is(App::Yath::Script::seed_hash(), 1, 'returns 1 when PERL_HASH_SEED is not set');
    }
    ok(defined $ENV{PERL_HASH_SEED}, 'PERL_HASH_SEED is now set');
    like($ENV{PERL_HASH_SEED}, qr/^\d{8}$/, 'seed is 8 digits (YYYYMMDD)');
    like($output, qr/PERL_HASH_SEED not set/, 'prints message about setting seed');
};

subtest 'parse_new_dev_libs' => sub {
    # No -D args, should return 0
    local @ARGV = ('test', '--verbose');
    is(App::Yath::Script::parse_new_dev_libs(), 0, 'returns 0 with no -D args');

    # Stops at --
    local @ARGV = ('--', '-D');
    is(App::Yath::Script::parse_new_dev_libs(), 0, 'stops at --');

    # Stops at ::
    local @ARGV = ('::', '-D');
    is(App::Yath::Script::parse_new_dev_libs(), 0, 'stops at ::');
};

done_testing;
