use Test2::V0;
use strict;
use warnings;

use File::Temp qw/tempdir/;
use File::Spec ();

use Test2::Harness2::Preloader;

subtest "bootstrap_script compiles" => sub {
    my $script = Test2::Harness2::Preloader->bootstrap_script;
    like($script, qr/setjump/,            "setjump called");
    like($script, qr/_begin_bootstrap/,   "BEGIN bootstrap invoked");
    like($script, qr/_serve/,             "serve branch present");
    like($script, qr/_post_jump_launch/,  "post-jump branch present");

    # Syntax-check the script with a real dummy config so BEGIN does not
    # abort the compile. perl -c still runs BEGIN blocks; a missing config
    # file would die inside _begin_bootstrap.
    my $dir = tempdir(CLEANUP => 1);
    my $cfg = "$dir/cfg.json";
    open my $fh, '>', $cfg or die $!;
    print $fh "{}";
    close $fh;

    my $rc = system($^X, '-Ilib', '-c', '-e', $script, '--', $cfg);
    is($rc, 0, "bootstrap script is syntactically valid");
};

subtest "build_exec_argv shape" => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $cfg = "$dir/cfg.json";
    open my $fh, '>', $cfg or die $!;
    print $fh "{}";
    close $fh;

    my @argv = Test2::Harness2::Preloader->build_exec_argv(config_file => $cfg);
    is($argv[0], $^X, "starts with current perl");
    ok((grep { $_ eq '-e' } @argv), "contains -e");
    is($argv[-1], $cfg, "config file is last argv");
    ok((grep { /^-I/ } @argv), "carries -I entries from current \@INC");
};

subtest "write_config_file round-trip" => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $config = {
        workdir  => $dir,
        preload  => ['Carp'],
        name     => 'preloader',
    };

    my $path = Test2::Harness2::Preloader->write_config_file($dir, $config);
    ok(-f $path, "config file exists");

    open my $fh, '<', $path or die $!;
    local $/;
    my $json = <$fh>;
    close $fh;

    require Test2::Harness2::Util::JSON;
    my $got = Test2::Harness2::Util::JSON::decode_json($json);
    is($got->{workdir}, $dir,                "workdir round-trip");
    is($got->{preload}, ['Carp'],            "preload list round-trip");
    is($got->{name},    'preloader',         "name round-trip");
};

subtest "_begin_bootstrap loads plain modules" => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $config = {
        workdir => $dir,
        preload => ['Carp'],
    };
    my $cfg_file = Test2::Harness2::Preloader->write_config_file($dir, $config);

    # Write a probe script to disk so shell quoting does not interfere.
    my $probe = File::Spec->catfile($dir, 'probe.pl');
    open my $pfh, '>', $probe or die $!;
    print $pfh <<'PROBE';
use strict;
use warnings;
use Test2::Harness2::Preloader;
Test2::Harness2::Preloader->_begin_bootstrap($ARGV[0]);
print "ok\n" if $INC{'Carp.pm'};
print "meta_count:", scalar(@{$Test2::Harness2::Preloader::CONFIG->{_meta}->stage_list}), "\n";
exit 0;
PROBE
    close $pfh;

    my $out = `$^X -Ilib $probe $cfg_file 2>&1`;
    like($out, qr/^ok\n/m,       "Carp loaded via plain preload");
    like($out, qr/meta_count:0/, "no stages since no DSL preload");
};

subtest "_begin_bootstrap loads DSL preloads and merges meta" => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $mod_dir = File::Spec->catdir($dir, 'BootDsl');
    require File::Path;
    File::Path::make_path($mod_dir);
    open my $fh, '>', File::Spec->catfile($mod_dir, 'Pre.pm') or die $!;
    print $fh <<'EOPM';
package BootDsl::Pre;
use Test2::Harness2::Preload;
stage MyStage => sub { preload 'Carp' };
1;
EOPM
    close $fh;

    my $config = {
        workdir => $dir,
        preload => ['BootDsl::Pre'],
    };
    my $cfg_file = Test2::Harness2::Preloader->write_config_file($dir, $config);

    my $probe = File::Spec->catfile($dir, 'probe.pl');
    open my $pfh, '>', $probe or die $!;
    print $pfh <<'PROBE';
use strict;
use warnings;
use Test2::Harness2::Preloader;
Test2::Harness2::Preloader->_begin_bootstrap($ARGV[0]);
my $meta = $Test2::Harness2::Preloader::CONFIG->{_meta};
print "stages:", join(",", sort keys %{$meta->stage_lookup}), "\n";
exit 0;
PROBE
    close $pfh;

    my $out = `$^X -Ilib -I$dir $probe $cfg_file 2>&1`;
    like($out, qr/stages:MyStage/, "DSL preload registered its stage");
};

done_testing;
