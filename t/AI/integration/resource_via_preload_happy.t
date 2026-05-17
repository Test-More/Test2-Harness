# HARNESS2: conflicts yath
use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep/;
use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

# Smoke test: a resource declares preferred_preload against a name that
# does NOT match any live PreloadService on the daemon. The harness's
# dispatch path (Role::ResourceServiceHost::_start_service_entry,
# PreloadRouter::find_eligible, _ipcm_service_standalone) must
# tolerate the miss and let the daemon come up cleanly with the
# resource registered and visible to `yath resources`. The
# name-match happy path is covered separately.

my $dir = tempdir(CLEANUP => 1);

my $lib = "$dir/lib";
mkdir $lib                              or die "mkdir $lib: $!";
mkdir "$lib/Test2"                      or die "mkdir $lib/Test2: $!";
mkdir "$lib/Test2/Harness2"             or die "mkdir $lib/Test2/Harness2: $!";
mkdir "$lib/Test2/Harness2/Resource"    or die "mkdir $lib/Test2/Harness2/Resource: $!";

# Test2::Harness2::Resource is not a real module in this branch; the
# canonical resource base is the Role::Tiny role
# Test2::Harness2::Role::Resource, composed via Object::HashBase's
# `&Role` syntax (see e.g. Resource::JobCount). The stub mirrors that
# pattern as a minimal viable consumer.
open my $rfh, '>', "$lib/Test2/Harness2/Resource/MyAppPool.pm"
    or die "open MyAppPool.pm: $!";
print $rfh <<'EOF';
package Test2::Harness2::Resource::MyAppPool;
use strict;
use warnings;

use Object::HashBase qw{
    &Test2::Harness2::Role::Resource
};

sub preferred_preload { 'myapp' }
sub resource_name     { 'myapppool' }
sub restartable       { 1 }
sub status            { { resource => 'myapppool' } }
sub needed            { 0 }
sub available         { 0 }
1;
EOF
close $rfh;

# Start a daemon with the new resource. No preload is configured, so
# 'myapp' will not match anything; the resource simply registers with
# the harness and surfaces through `yath resources`. `--dev-lib` puts
# the stub directory on @INC so -R can resolve the module.
yath(
    command => 'start',
    args    => [
        "--workdir=$dir",
        '-R', 'Test2::Harness2::Resource::MyAppPool',
        "--dev-lib=$lib",
    ],
    exit => 0,
);

yath(
    command => 'resources',
    args    => ["--workdir=$dir"],
    exit    => 0,
    test    => sub {
        my $o = shift;
        like($o->{output}, qr/myapppool/i, 'pool resource appears in resources output');
    },
);

yath(command => 'stop', args => ["--workdir=$dir", '--timeout=10'], exit => 0);

done_testing;
