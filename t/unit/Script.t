use strict;
use warnings;

use Test2::V0;

# Pre-load so the in-memory STDOUT redirects below still work after a
# `local @INC = (...)` swap blocks autoloading of PerlIO/scalar.pm.
use PerlIO::scalar;

use App::Yath::Script qw/clean_path find_in_updir find_rc_updir mod2file script module/;
use Cwd qw/realpath getcwd/;
use File::Spec;
use File::Temp qw/tempdir/;
use File::Path();

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

subtest '_collect_dev_libs' => sub {
    is([App::Yath::Script::_collect_dev_libs()], [], 'empty input -> empty list');

    is(
        [App::Yath::Script::_collect_dev_libs('test', '--verbose', 'foo')],
        [],
        'no -D tokens -> empty list',
    );

    is(
        [App::Yath::Script::_collect_dev_libs('-D')],
        [map { clean_path($_) } 'lib', 'blib/lib', 'blib/arch'],
        'bare -D adds default trio',
    );

    is(
        [App::Yath::Script::_collect_dev_libs('--dev-lib')],
        [map { clean_path($_) } 'lib', 'blib/lib', 'blib/arch'],
        'bare --dev-lib adds default trio',
    );

    is(
        [App::Yath::Script::_collect_dev_libs('--dev-libs')],
        [map { clean_path($_) } 'lib', 'blib/lib', 'blib/arch'],
        'bare --dev-libs adds default trio',
    );

    is(
        [App::Yath::Script::_collect_dev_libs('-D=/foo/bar')],
        ['/foo/bar'],
        '-D=path adds the path',
    );

    is(
        [App::Yath::Script::_collect_dev_libs('--dev-lib=/foo/bar')],
        ['/foo/bar'],
        '--dev-lib=path adds the path',
    );

    is(
        [App::Yath::Script::_collect_dev_libs('--dev-libs=/foo/bar')],
        ['/foo/bar'],
        '--dev-libs=path adds the path',
    );

    is(
        [App::Yath::Script::_collect_dev_libs('-D=/a,/b,/c')],
        ['/a', '/b', '/c'],
        'comma-separated paths split',
    );

    is(
        [App::Yath::Script::_collect_dev_libs('-D=/foo', 'middle', '--dev-libs=/bar')],
        ['/foo', '/bar'],
        'mixed args, only -D tokens collected',
    );

    is(
        [App::Yath::Script::_collect_dev_libs('--', '-D=/should/be/ignored')],
        [],
        'stops at --',
    );

    is(
        [App::Yath::Script::_collect_dev_libs('::', '-D=/should/be/ignored')],
        [],
        'stops at ::',
    );

    is(
        [App::Yath::Script::_collect_dev_libs('-D=/before', '--', '-D=/after')],
        ['/before'],
        '-D before -- collected, after -- ignored',
    );

    # Glob expansion: build a temp dir with two child dirs and confirm
    # that a glob pattern in -D=... expands via glob().
    my $tdir = tempdir(CLEANUP => 1);
    mkdir File::Spec->catdir($tdir, 'one') or die $!;
    mkdir File::Spec->catdir($tdir, 'two') or die $!;
    my $pattern = File::Spec->catdir($tdir, '*');
    my @expected = sort glob($pattern);
    my @paths    = App::Yath::Script::_collect_dev_libs("-D=$pattern");
    my @got      = sort @paths;
    is(\@got, \@expected, 'glob pattern expanded');
};

subtest '_install_dev_libs' => sub {
    is(App::Yath::Script::_install_dev_libs(), 0, 'empty input returns 0');

    {
        local @INC = ('/already/here');
        is(
            App::Yath::Script::_install_dev_libs('/already/here'),
            0,
            'path already in @INC -> 0, no change',
        );
        is(\@INC, ['/already/here'], '@INC unchanged');
    }

    {
        local @INC = ('/orig');
        is(
            App::Yath::Script::_install_dev_libs('/new/path'),
            1,
            'new path -> returns 1',
        );
        is(\@INC, ['/new/path', '/orig'], 'unshifted to front of @INC');
    }

    {
        local @INC = ('/orig');
        is(
            App::Yath::Script::_install_dev_libs('/new1', '/orig', '/new2'),
            1,
            'mixed new and existing -> returns 1',
        );
        is(\@INC, ['/new1', '/new2', '/orig'], 'only new paths added, in order');
    }
};

subtest '_rc_global_tokens' => sub {
    my $tdir = tempdir(CLEANUP => 1);

    my $write = sub {
        my ($name, $body) = @_;
        my $path = File::Spec->catfile($tdir, $name);
        open(my $fh, '>', $path) or die "Cannot write $path: $!";
        print $fh $body;
        close $fh;
        return $path;
    };

    is(
        [App::Yath::Script::_rc_global_tokens($write->('empty.rc', ''))],
        [],
        'empty file -> no tokens',
    );

    my $f1 = $write->('basic.rc', <<'EOF');
# leading comment
-D=/path/one

--foo bar
--baz=qux
--flag

[test]
--ignored=should-not-appear
EOF
    is(
        [App::Yath::Script::_rc_global_tokens($f1)],
        ['-D=/path/one', '--foo', 'bar', '--baz=qux', '--flag'],
        'tokens from global section, stops at [section]',
    );

    my $f2 = $write->('comments.rc', <<'EOF');
-D=/keep ; trailing semicolon comment
--foo # trailing hash comment
   --bar=baz
EOF
    is(
        [App::Yath::Script::_rc_global_tokens($f2)],
        ['-D=/keep', '--foo', '--bar=baz'],
        'inline comments stripped, whitespace trimmed',
    );

    my $f3 = $write->('section_first.rc', <<'EOF');
[test]
-D=/in/section
EOF
    is(
        [App::Yath::Script::_rc_global_tokens($f3)],
        [],
        'no global tokens when [section] is the first non-blank line',
    );
};

subtest 'parse_rc_dev_libs' => sub {
    is(App::Yath::Script::parse_rc_dev_libs(),               0, 'no args -> 0');
    is(App::Yath::Script::parse_rc_dev_libs(undef),          0, 'undef -> 0');
    is(App::Yath::Script::parse_rc_dev_libs('', ''),         0, 'empty strings -> 0');
    is(App::Yath::Script::parse_rc_dev_libs('/no/such/rc'),  0, 'missing file -> 0');

    my $tdir = tempdir(CLEANUP => 1);

    my $write = sub {
        my ($name, $body) = @_;
        my $path = File::Spec->catfile($tdir, $name);
        open(my $fh, '>', $path) or die "Cannot write $path: $!";
        print $fh $body;
        close $fh;
        return $path;
    };

    {
        my $rc = $write->('with_d.rc', <<'EOF');
-D=/rc/lib

[test]
--workdir /tmp
EOF
        local @INC = ('/orig');
        is(
            App::Yath::Script::parse_rc_dev_libs($rc),
            1,
            '-D=/rc/lib in global -> returns 1',
        );
        is(\@INC, ['/rc/lib', '/orig'], 'path unshifted to @INC');
    }

    {
        my $rc = $write->('section_only.rc', <<'EOF');
[test]
-D=/in/section/should/not/apply
EOF
        local @INC = ('/orig');
        is(
            App::Yath::Script::parse_rc_dev_libs($rc),
            0,
            '-D in [section] is ignored',
        );
        is(\@INC, ['/orig'], '@INC unchanged');
    }

    {
        my $rc1 = $write->('multi1.rc', "-D=/from/rc1\n");
        my $rc2 = $write->('multi2.rc', "-D=/from/rc2\n");
        local @INC = ('/orig');
        is(
            App::Yath::Script::parse_rc_dev_libs($rc1, $rc2),
            1,
            'two rc files both contribute',
        );
        is(\@INC, ['/from/rc1', '/from/rc2', '/orig'], 'both paths unshifted');
    }

    {
        my $rc = $write->('bare.rc', "-D\n");
        local @INC = ('/orig');
        is(
            App::Yath::Script::parse_rc_dev_libs($rc),
            1,
            'bare -D in rc -> defaults installed',
        );
        my @defaults = map { clean_path($_) } 'lib', 'blib/lib', 'blib/arch';
        is(\@INC, [@defaults, '/orig'], 'default trio unshifted');
    }

    {
        # Consistency: rc and CLI share the same parser, so the same
        # token strings must produce the same path list.
        my $rc = $write->('consistent.rc', <<'EOF');
-D=/x,/y
--dev-libs=/z
EOF
        my @from_rc  = App::Yath::Script::_collect_dev_libs(
            App::Yath::Script::_rc_global_tokens($rc));
        my @from_cli = App::Yath::Script::_collect_dev_libs(
            '-D=/x,/y', '--dev-libs=/z');
        is(\@from_rc, \@from_cli, 'rc tokens and cli args yield same path list');
    }
};

subtest 'find_local_version' => sub {
    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    is(App::Yath::Script::find_local_version(), undef, 'no ./lib -> undef');

    mkdir 'lib' or die $!;
    is(App::Yath::Script::find_local_version(), undef, 'empty ./lib tree -> undef');

    my $script_dir = File::Spec->catdir($dir, 'lib', 'App', 'Yath', 'Script');
    File::Path::make_path($script_dir);

    is(App::Yath::Script::find_local_version(), undef, 'no V#.pm files -> undef');

    open(my $fh1, '>', File::Spec->catfile($script_dir, 'V2.pm')) or die $!;
    close($fh1);
    is(App::Yath::Script::find_local_version(), 2, 'single V2.pm');

    open(my $fh2, '>', File::Spec->catfile($script_dir, 'V5.pm')) or die $!;
    close($fh2);
    open(my $fh3, '>', File::Spec->catfile($script_dir, 'V3.pm')) or die $!;
    close($fh3);

    is(App::Yath::Script::find_local_version(), 5, 'highest V# wins');

    # A non-V file should be ignored.
    open(my $fh4, '>', File::Spec->catfile($script_dir, 'Other.pm')) or die $!;
    close($fh4);
    is(App::Yath::Script::find_local_version(), 5, 'non-V file ignored');

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
};

subtest 'install_local_lib' => sub {
    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    {
        local @INC = ('/orig');
        my $output = '';
        local *STDOUT;
        open(STDOUT, '>', \$output) or die "Cannot redirect STDOUT: $!";
        is(App::Yath::Script::install_local_lib(), undef, 'no local lib -> undef');
        is(\@INC, ['/orig'], '@INC unchanged');
        is($output, '', 'no print');
    }

    my $script_dir = File::Spec->catdir($dir, 'lib', 'App', 'Yath', 'Script');
    File::Path::make_path($script_dir);
    open(my $fh, '>', File::Spec->catfile($script_dir, 'V7.pm')) or die $!;
    close($fh);

    my $expected_lib = clean_path(File::Spec->catdir($dir, 'lib'));

    {
        local @INC = ('/orig');
        my $output = '';
        {
            local *STDOUT;
            open(STDOUT, '>', \$output) or die "Cannot redirect STDOUT: $!";
            is(App::Yath::Script::install_local_lib(), 7, 'returns highest version');
        }
        is(\@INC, [$expected_lib, '/orig'], 'lib unshifted to @INC');
        like($output, qr/Detected App::Yath::Script::V# modules/, 'prints detection message');
        like($output, qr/\Q$expected_lib\E/, 'prints lib path');
    }

    {
        # Re-exec idempotency: lib already in @INC -> no print, no unshift.
        local @INC = ($expected_lib, '/orig');
        my $output = '';
        {
            local *STDOUT;
            open(STDOUT, '>', \$output) or die "Cannot redirect STDOUT: $!";
            is(App::Yath::Script::install_local_lib(), 7, 'returns version even when already installed');
        }
        is(\@INC, [$expected_lib, '/orig'], '@INC unchanged');
        is($output, '', 'no print on repeat call');
    }

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
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

subtest 'find_rc_updir - plain unversioned file returns no version' => sub {
    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    open(my $fh, '>', File::Spec->catfile($dir, '.yath.rc')) or die $!;
    close($fh);

    my ($path, $v) = find_rc_updir('.yath');
    ok(defined $path, 'found plain rc file');
    is($v, undef, 'plain .yath.rc captures no version (caller decides)');
    like($path, qr/\.yath\.rc$/, 'path ends with .yath.rc');

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
};

subtest 'find_rc_updir - highest versioned file wins' => sub {
    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    for my $v (2, 5, 3) {
        open(my $fh, '>', File::Spec->catfile($dir, ".yath.v${v}.rc")) or die $!;
        close($fh);
    }

    my ($path, $v) = find_rc_updir('.yath');
    is($v, 5, 'highest versioned (V5) wins over V2 and V3');
    like($path, qr/\.yath\.v5\.rc$/, 'path is the highest versioned file');

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
};

subtest 'find_rc_updir - mixed lowercase and uppercase V picks highest' => sub {
    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    open(my $fh1, '>', File::Spec->catfile($dir, '.yath.v2.rc')) or die $!;
    close($fh1);
    open(my $fh2, '>', File::Spec->catfile($dir, '.yath.V4.rc')) or die $!;
    close($fh2);

    my ($path, $v) = find_rc_updir('.yath');
    is($v, 4, 'V4 (uppercase) wins over v2 (lowercase)');
    like($path, qr/\.yath\.V4\.rc$/, 'path is the V4 file');

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

subtest 'find_rc_updir - plain user rc returns no version' => sub {
    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    open(my $fh, '>', File::Spec->catfile($dir, '.yath.user.rc')) or die $!;
    close($fh);

    my ($path, $v) = find_rc_updir('.yath.user');
    ok(defined $path, 'found plain user rc file');
    is($v, undef, 'plain .yath.user.rc captures no version');

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

subtest 'find_rc_files - cli_version with versioned rc' => sub {
    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    open(my $fh, '>', File::Spec->catfile($dir, '.yath.v3.rc')) or die $!;
    close($fh);
    open(my $fh2, '>', File::Spec->catfile($dir, '.yath.user.v3.rc')) or die $!;
    close($fh2);

    my ($cfg, $ucfg, $v) = App::Yath::Script::find_rc_files(3);
    like($cfg,  qr/\.yath\.v3\.rc$/,        'project rc found');
    like($ucfg, qr/\.yath\.user\.v3\.rc$/,  'user rc found');
    is($v, 3, 'cli_version returned');

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
};

subtest 'find_rc_files - cli_version falls back to plain rc' => sub {
    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    # Only plain rc files exist; no .yath.v3.rc / .yath.user.v3.rc.
    open(my $fh,  '>', File::Spec->catfile($dir, '.yath.rc'))      or die $!;
    close($fh);
    open(my $fh2, '>', File::Spec->catfile($dir, '.yath.user.rc')) or die $!;
    close($fh2);

    my ($cfg, $ucfg, $v) = App::Yath::Script::find_rc_files(3);
    like($cfg,  qr/\.yath\.rc$/,       'plain project rc used as fallback');
    like($ucfg, qr/\.yath\.user\.rc$/, 'plain user rc used as fallback');
    is($v, 3, 'cli_version preserved across fallback');

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
};

subtest 'find_rc_files - cli_version with no rc files' => sub {
    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    my ($cfg, $ucfg, $v) = App::Yath::Script::find_rc_files(2);
    is($cfg,  undef, 'no project rc');
    is($ucfg, undef, 'no user rc');
    is($v, 2, 'cli_version still returned without rc files');

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
};

subtest 'find_rc_files - no cli_version, versioned rc files' => sub {
    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    open(my $fh, '>', File::Spec->catfile($dir, '.yath.v4.rc')) or die $!;
    close($fh);
    open(my $fh2, '>', File::Spec->catfile($dir, '.yath.user.v6.rc')) or die $!;
    close($fh2);

    my ($cfg, $ucfg, $v) = App::Yath::Script::find_rc_files(undef);
    like($cfg,  qr/\.yath\.v4\.rc$/,       'project rc found');
    like($ucfg, qr/\.yath\.user\.v6\.rc$/, 'user rc found');
    is($v, 6, 'user version takes precedence over project version');

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
};

subtest 'find_rc_files - no cli_version, plain rc files only' => sub {
    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    open(my $fh,  '>', File::Spec->catfile($dir, '.yath.rc'))      or die $!;
    close($fh);
    open(my $fh2, '>', File::Spec->catfile($dir, '.yath.user.rc')) or die $!;
    close($fh2);

    my ($cfg, $ucfg, $v) = App::Yath::Script::find_rc_files(undef);
    like($cfg,  qr/\.yath\.rc$/,       'plain project rc used');
    like($ucfg, qr/\.yath\.user\.rc$/, 'plain user rc used');
    is($v, undef, 'no version captured -- caller falls back to local lib / V1 default');

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
};

subtest 'find_rc_files - no cli_version, no rc files' => sub {
    my $dir = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";

    my ($cfg, $ucfg, $v) = App::Yath::Script::find_rc_files(undef);
    is($cfg,  undef, 'no project rc');
    is($ucfg, undef, 'no user rc');
    is($v,    undef, 'no version');

    chdir $ORIG_DIR or die "Cannot chdir back: $!";
};

subtest 'load_yath_module - explicit V0 loads with warning' => sub {
    my $warning = '';
    my $mod;
    {
        local $SIG{__WARN__} = sub { $warning .= $_[0] };
        $mod = App::Yath::Script::load_yath_module(0);
    }
    is($mod, 'App::Yath::Script::V0', 'V0 returned');
    like($warning, qr/Version '0' is for validating/, 'V0 warning emitted');
};

subtest 'load_yath_module - explicit unknown version dies' => sub {
    like(
        dies { App::Yath::Script::load_yath_module(987654) },
        qr/Could not load App::Yath::Script::V987654/,
        'unknown explicit version dies',
    );
};

subtest 'find_installed_versions - excludes V0, sorted highest-first' => sub {
    my $tdir = tempdir(CLEANUP => 1);
    my $sdir = File::Spec->catdir($tdir, 'App', 'Yath', 'Script');
    File::Path::make_path($sdir);
    for my $v (0, 3, 17, 5) {
        open(my $fh, '>', File::Spec->catfile($sdir, "V${v}.pm")) or die $!;
        close($fh);
    }

    local @INC = ($tdir);
    my @vers = App::Yath::Script::find_installed_versions();
    is(\@vers, [17, 5, 3], 'highest-first, V0 excluded');
};

subtest 'load_latest_yath_module - returns highest installable' => sub {
    # Use distinct version numbers across subtests so %INC caching from
    # one test does not leak into another.
    my $tdir = tempdir(CLEANUP => 1);
    my $sdir = File::Spec->catdir($tdir, 'App', 'Yath', 'Script');
    File::Path::make_path($sdir);
    for my $v (101, 109) {
        open(my $fh, '>', File::Spec->catfile($sdir, "V${v}.pm")) or die $!;
        print $fh "package App::Yath::Script::V${v}; 1;\n";
        close($fh);
    }

    local @INC = ($tdir);
    my $mod = App::Yath::Script::load_latest_yath_module();
    is($mod, 'App::Yath::Script::V109', 'highest installed selected');
};

subtest 'load_latest_yath_module - falls back when highest fails to load' => sub {
    my $tdir = tempdir(CLEANUP => 1);
    my $sdir = File::Spec->catdir($tdir, 'App', 'Yath', 'Script');
    File::Path::make_path($sdir);

    # V299 has a syntax error; V242 loads cleanly.
    open(my $fh, '>', File::Spec->catfile($sdir, 'V299.pm')) or die $!;
    print $fh "package App::Yath::Script::V299;\nthis is not valid perl;\n1;\n";
    close($fh);

    open($fh, '>', File::Spec->catfile($sdir, 'V242.pm')) or die $!;
    print $fh "package App::Yath::Script::V242; 1;\n";
    close($fh);

    local @INC = ($tdir);
    my $mod = App::Yath::Script::load_latest_yath_module();
    is($mod, 'App::Yath::Script::V242', 'falls back past broken highest');
};

subtest 'load_latest_yath_module - dies when none installed' => sub {
    my $empty = tempdir(CLEANUP => 1);
    local @INC = ($empty);
    like(
        dies { App::Yath::Script::load_latest_yath_module() },
        qr/No App::Yath .* modules appear to be installed/,
        'dies with helpful message when no V# modules in @INC',
    );
};

done_testing;
