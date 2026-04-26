use strict;
use warnings;

use Test2::V0;

use App::Yath::Script qw/clean_path find_in_updir find_rc_updir mod2file script module/;
use Cwd qw/realpath getcwd/;
use File::Spec;
use File::Temp qw/tempdir/;

my $ORIG_DIR = getcwd();

my $can_symlink = do {
    my $td = tempdir(CLEANUP => 1);
    my $src = File::Spec->catfile($td, 'src');
    open(my $fh, '>', $src) or die "Cannot create $src: $!";
    close($fh);
    my $dst = File::Spec->catfile($td, 'dst');
    eval { symlink($src, $dst); 1 } && -l $dst;
};

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

subtest 'find_rc_updir - versioned file' => sub {
    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    open(my $fh, '>', File::Spec->catfile($dir, '.yath.v2.rc')) or die $!;
    close($fh);

    my ($path, $v) = find_rc_updir('.yath');
    ok(defined $path, 'found versioned rc file');
    is($v, 2, 'version extracted from filename');
    like($path, qr/\.yath\.v2\.rc$/, 'path ends with .yath.v2.rc');

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
};

subtest 'find_rc_updir - plain unversioned file defaults to V1' => sub {
    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    open(my $fh, '>', File::Spec->catfile($dir, '.yath.rc')) or die $!;
    close($fh);

    my ($path, $v) = find_rc_updir('.yath');
    ok(defined $path, 'found plain rc file');
    is($v, 1, 'plain .yath.rc defaults to V1');
    like($path, qr/\.yath\.rc$/, 'path ends with .yath.rc');

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
};

subtest 'find_rc_updir - symlink to versioned file' => sub {
    skip_all "symlink not supported on this platform" unless $can_symlink;

    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    my $versioned = File::Spec->catfile($dir, '.yath.v3.rc');
    open(my $fh, '>', $versioned) or die $!;
    close($fh);

    my $link = File::Spec->catfile($dir, '.yath.rc');
    symlink('.yath.v3.rc', $link) or die "Cannot create symlink: $!";

    my ($path, $v) = find_rc_updir('.yath');
    ok(defined $path, 'found symlinked rc file');
    is($v, 3, 'version extracted from symlink target');
    like($path, qr/\.yath\.rc$/, 'path is the symlink (.yath.rc), not the target');

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
};

subtest 'find_rc_updir - symlink takes priority over versioned file' => sub {
    skip_all "symlink not supported on this platform" unless $can_symlink;

    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    # Create a versioned file for V2
    open(my $fh2, '>', File::Spec->catfile($dir, '.yath.v2.rc')) or die $!;
    close($fh2);

    # Create a different versioned file for V3
    open(my $fh3, '>', File::Spec->catfile($dir, '.yath.v3.rc')) or die $!;
    close($fh3);

    # Symlink .yath.rc -> .yath.v3.rc
    symlink('.yath.v3.rc', File::Spec->catfile($dir, '.yath.rc'))
        or die "Cannot create symlink: $!";

    my ($path, $v) = find_rc_updir('.yath');
    ok(defined $path, 'found rc file');
    is($v, 3, 'symlink target version (V3) takes priority over standalone V2');
    like($path, qr/\.yath\.rc$/, 'returned the symlink path');

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
};

subtest 'find_rc_updir - versioned file takes priority over plain' => sub {
    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    # Both a plain .yath.rc and a versioned .yath.v2.rc
    open(my $fh1, '>', File::Spec->catfile($dir, '.yath.rc')) or die $!;
    close($fh1);
    open(my $fh2, '>', File::Spec->catfile($dir, '.yath.v2.rc')) or die $!;
    close($fh2);

    my ($path, $v) = find_rc_updir('.yath');
    ok(defined $path, 'found rc file');
    is($v, 2, 'versioned file (V2) takes priority over plain V1 default');

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
};

subtest 'find_rc_updir - no rc file returns empty' => sub {
    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    my ($path, $v) = find_rc_updir('.yath');
    is($path, undef, 'no path when no rc file exists');
    is($v,    undef, 'no version when no rc file exists');

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
};

subtest 'find_rc_updir - user rc files' => sub {
    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    open(my $fh, '>', File::Spec->catfile($dir, '.yath.user.v5.rc')) or die $!;
    close($fh);

    my ($path, $v) = find_rc_updir('.yath.user');
    ok(defined $path, 'found user versioned rc file');
    is($v, 5, 'version extracted from user rc filename');
    like($path, qr/\.yath\.user\.v5\.rc$/, 'path matches user versioned pattern');

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
};

subtest 'find_rc_updir - user symlink to versioned file' => sub {
    skip_all "symlink not supported on this platform" unless $can_symlink;

    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    open(my $fh, '>', File::Spec->catfile($dir, '.yath.user.v4.rc')) or die $!;
    close($fh);
    symlink('.yath.user.v4.rc', File::Spec->catfile($dir, '.yath.user.rc'))
        or die "Cannot create symlink: $!";

    my ($path, $v) = find_rc_updir('.yath.user');
    ok(defined $path, 'found user symlinked rc file');
    is($v, 4, 'version extracted from user symlink target');
    like($path, qr/\.yath\.user\.rc$/, 'returned the symlink path');

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
};

subtest 'find_rc_updir - plain user rc defaults to V1' => sub {
    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    open(my $fh, '>', File::Spec->catfile($dir, '.yath.user.rc')) or die $!;
    close($fh);

    my ($path, $v) = find_rc_updir('.yath.user');
    ok(defined $path, 'found plain user rc file');
    is($v, 1, 'plain .yath.user.rc defaults to V1');

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
};

subtest 'find_rc_updir - uppercase V in filename' => sub {
    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    open(my $fh, '>', File::Spec->catfile($dir, '.yath.V2.rc')) or die $!;
    close($fh);

    my ($path, $v) = find_rc_updir('.yath');
    ok(defined $path, 'found uppercase V rc file');
    is($v, 2, 'version extracted from uppercase V filename');
    like($path, qr/\.yath\.V2\.rc$/, 'path ends with .yath.V2.rc');

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
};

subtest 'find_rc_updir - uppercase V user rc' => sub {
    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    open(my $fh, '>', File::Spec->catfile($dir, '.yath.user.V3.rc')) or die $!;
    close($fh);

    my ($path, $v) = find_rc_updir('.yath.user');
    ok(defined $path, 'found uppercase V user rc file');
    is($v, 3, 'version extracted from uppercase V user filename');

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
};

subtest 'find_rc_updir - symlink to uppercase V file' => sub {
    skip_all "symlink not supported on this platform" unless $can_symlink;

    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    open(my $fh, '>', File::Spec->catfile($dir, '.yath.V4.rc')) or die $!;
    close($fh);
    symlink('.yath.V4.rc', File::Spec->catfile($dir, '.yath.rc'))
        or die "Cannot create symlink: $!";

    my ($path, $v) = find_rc_updir('.yath');
    ok(defined $path, 'found symlink to uppercase V file');
    is($v, 4, 'version extracted from uppercase V symlink target');
    like($path, qr/\.yath\.rc$/, 'returned the symlink path');

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
};

subtest 'find_rc_updir - searches parent directories' => sub {
    my $parent = tempdir(CLEANUP => 1);
    my $child  = File::Spec->catdir($parent, 'subdir');
    mkdir $child or die "Cannot mkdir $child: $!";

    open(my $fh, '>', File::Spec->catfile($parent, '.yath.v7.rc')) or die $!;
    close($fh);

    chdir $child or die "Cannot chdir to $child: $!";

    my ($path, $v) = find_rc_updir('.yath');
    ok(defined $path, 'found rc file in parent directory');
    is($v, 7, 'correct version from parent directory');

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
};

done_testing;
