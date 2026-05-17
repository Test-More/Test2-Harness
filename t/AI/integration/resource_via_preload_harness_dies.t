# HARNESS2: conflicts yath
use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep/;
use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

# Lifecycle invariant: if the harness service dies, every resource
# service that was spawned via_preload must exit on its own within
# the watch_pids grace window. PreloadRouter::spawn_service_via_preload
# injects the harness pid into the grandchild's ctor_args watch_pids,
# so IPC::Manager::Role::Service is contracted to exit when that pid
# disappears.
#

# Setup mirrors resource_via_preload_namematch.t (see that test for
# the prose explanation of why AAPreloader/MyAppPool are shaped the
# way they are).
#
# Both pids the test needs come out of a single `yath ps` call: the
# harness pid is in the "Daemon: pid=N" header line and the resource
# service pid is in the Services table row for resource-myappservice.

my $dir = tempdir(CLEANUP => 1);

my $lib = "$dir/lib";
mkdir $lib                           or die "mkdir $lib: $!";
mkdir "$lib/Test2"                   or die "mkdir $lib/Test2: $!";
mkdir "$lib/Test2/Harness2"          or die "mkdir $lib/Test2/Harness2: $!";
mkdir "$lib/Test2/Harness2/Resource" or die "mkdir $lib/Test2/Harness2/Resource: $!";

open my $pfh, '>', "$lib/Test2/Harness2/Resource/AAPreloader.pm"
    or die "open AAPreloader.pm: $!";
print $pfh <<'EOF';
package Test2::Harness2::Resource::AAPreloader;
use strict;
use warnings;

use Test2::Harness2::Resource::Preload;
use parent -norequire, 'Test2::Harness2::Resource::Preload';

sub init {
    my $self = shift;
    $self->{name}    //= 'myapp';
    $self->{modules} //= [];
    $self->SUPER::init();
}

1;
EOF
close $pfh;

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

sub services {
    my @inc = grep { defined && length } @INC;
    my @cmd = map  { "-I$_" } @inc;

    return ([
        'Test2::Harness2::PreloadService',
        name             => 'myappservice',
        modules          => [],
        scope            => 'global',
        is_role_consumer => 0,
        exec             => { cmd => \@cmd, stay_in_begin => 1 },
    ]);
}

1;
EOF
close $rfh;

local $ENV{TABLE_TERM_SIZE} = 500;

yath(
    command => 'start',
    args    => [
        "--workdir=$dir",
        '-R', 'Test2::Harness2::Resource::AAPreloader',
        '-R', 'Test2::Harness2::Resource::MyAppPool',
        "--dev-lib=$lib",
    ],
    exit => 0,
);

# Single-pass extraction of both pids. Poll ps in fresh subprocesses
# until the via_preload row appears AND we can pull both the
# "Daemon: pid=N" header (harness pid) and the resource service pid
# (from the Services table row) from the same output.
my ($harness_pid, $service_pid);
my $last_output;
for (1 .. 40) {
    yath(
        command => 'ps',
        args    => ["--workdir=$dir"],
        exit    => 0,
        test    => sub {
            my $o = shift;
            $last_output = $o->{output};

            return unless $last_output =~ /resource-myappservice .*? \byes\b/x;

            ($harness_pid) = $last_output =~ /Daemon:\s+pid=(\d+)/;

            for my $line (split /\n/, $last_output) {
                if ($line =~ /\|\s*(\d+)\s*\|\s*resource-myappservice\s*\|/) {
                    $service_pid = $1;
                }
            }
        },
    );
    last if $harness_pid && $service_pid;
    sleep 0.25;
}

ok($harness_pid, "harness pid extracted ($harness_pid)")
    or diag "last ps output:\n$last_output";
ok($service_pid, "service pid extracted ($service_pid)")
    or diag "last ps output:\n$last_output";

ok(kill(0, $harness_pid), 'harness alive pre-kill');
ok(kill(0, $service_pid), 'service alive pre-kill');

# SIGKILL ensures we exercise the watch_pids contract directly: no
# orderly harness teardown can shut the service down via in-band
# termination, so a service exit can only come from the
# Role::Service watch_pids polling.
kill 'KILL', $harness_pid;

my $harness_gone = 0;
for (1 .. 40) {
    unless (kill 0, $harness_pid) {
        $harness_gone = 1;
        last;
    }
    sleep 0.25;
}
ok($harness_gone, 'harness exited after SIGKILL');

# Service must self-exit within the watch_pids grace window.
# Role::Service polls watch_pids every tick. 10s is well above the
# default tick interval.
my $service_gone = 0;
for (1 .. 40) {
    unless (kill 0, $service_pid) {
        $service_gone = 1;
        last;
    }
    sleep 0.25;
}
ok($service_gone, "service ($service_pid) exited within 10s of harness death (watch_pids contract)");

# No `yath stop` — harness is already dead. The orphaned preload (and
# anything else the harness was hosting) will be picked up by the
# init-as-subreaper / pid namespace later; no cleanup we can do here
# from the test harness side that would not race the kernel reaper.
done_testing;
