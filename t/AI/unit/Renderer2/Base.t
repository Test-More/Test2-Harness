use strict;
use warnings;

use Test2::V0;
use App::Yath2::Renderer2::Base;

my $r = App::Yath2::Renderer2::Base->new(
    log          => undef,
    ipc_endpoint => undef,
    parent_pid   => $$,
    command_pid  => $$,
    out_fh       => \*STDOUT,
    criticality  => 'best_effort',
);
isa_ok($r, ['App::Yath2::Renderer2::Base']);
is($r->criticality, 'best_effort', 'criticality set');

# Default criticality
my $r2 = App::Yath2::Renderer2::Base->new(
    log         => undef,
    parent_pid  => $$,
    command_pid => $$,
    out_fh      => \*STDOUT,
);
is($r2->criticality, 'best_effort', 'criticality defaults to best_effort');

# Two-hook contract per kind.
for my $kind (qw/run job service collector/) {
    ok($r->can("handle_${kind}_opened"), "has handle_${kind}_opened");
    ok($r->can("handle_${kind}_sealed"), "has handle_${kind}_sealed");
}

# Defaults are no-ops returning undef.
ok(!defined $r->handle_run_opened(undef),       'default run_opened returns undef');
ok(!defined $r->handle_run_sealed(undef),       'default run_sealed returns undef');
ok(!defined $r->handle_job_opened(undef),       'default job_opened returns undef');
ok(!defined $r->handle_job_sealed(undef),       'default job_sealed returns undef');
ok(!defined $r->handle_service_opened(undef),   'default service_opened returns undef');
ok(!defined $r->handle_service_sealed(undef),   'default service_sealed returns undef');
ok(!defined $r->handle_collector_opened(undef), 'default collector_opened returns undef');
ok(!defined $r->handle_collector_sealed(undef), 'default collector_sealed returns undef');

# Artifact monitor lifecycle.
ok($r->can('add_artifact_monitor'),    'add_artifact_monitor exists');
ok($r->can('remove_artifact_monitor'), 'remove_artifact_monitor exists');
ok($r->can('artifact_monitors'),       'artifact_monitors exists');
is([$r->artifact_monitors], [], 'no monitors initially');

# Register, list, remove.
my $monitor1 = bless {name => 'm1'}, 'TestMonitor';
my $monitor2 = bless {name => 'm2'}, 'TestMonitor';
$r->add_artifact_monitor('alpha', $monitor1);
$r->add_artifact_monitor('beta',  $monitor2);
is(scalar($r->artifact_monitors), 2, 'two monitors registered');

$r->remove_artifact_monitor('alpha');
is(scalar($r->artifact_monitors), 1, 'one monitor after removal');

# The remaining monitor is the beta one.
my ($remaining) = $r->artifact_monitors;
is($remaining->{name}, 'm2', 'remaining monitor is beta/m2');

# start/finish are no-ops (just verify they don't die).
ok(lives { $r->start },  'start no-ops');
ok(lives { $r->finish }, 'finish no-ops');

# Accessor checks.
is($r->parent_pid,  $$,       'parent_pid accessor');
is($r->command_pid, $$,       'command_pid accessor');
is($r->out_fh,      \*STDOUT, 'out_fh accessor');

# Internal state slots initialized to empty hashrefs.
is($r->_state, {}, '_state initialized to {}');

# _artifact_monitors still has beta after removing alpha.
my $remaining_map = $r->_artifact_monitors;
ok(exists $remaining_map->{beta},   'beta key still in monitor map');
ok(!exists $remaining_map->{alpha}, 'alpha key removed from monitor map');

# Required criticality.
my $rr = App::Yath2::Renderer2::Base->new(
    log         => undef,
    parent_pid  => $$,
    command_pid => $$,
    out_fh      => \*STDOUT,
    criticality => 'required',
);
is($rr->criticality, 'required', 'required criticality accepted');

# Invalid criticality.
like(
    dies {
        App::Yath2::Renderer2::Base->new(
            log         => undef,
            parent_pid  => $$,
            command_pid => $$,
            out_fh      => \*STDOUT,
            criticality => 'bogus',
        );
    },
    qr/invalid criticality/i,
    'rejects bogus criticality',
);

subtest 'on_artifact_change default no-op' => sub {
    my $r = App::Yath2::Renderer2::Base->new(
        log         => undef,
        parent_pid  => $$,
        command_pid => $$,
        out_fh      => \*STDOUT,
    );
    ok(!defined $r->on_artifact_change('alpha', undef), 'default no-op returns undef');
};

subtest 'ipc_disabled defaults false, mutator sets true' => sub {
    my $r = App::Yath2::Renderer2::Base->new(
        log         => undef,
        parent_pid  => $$,
        command_pid => $$,
        out_fh      => \*STDOUT,
    );
    is($r->ipc_disabled, 0, 'defaults to 0');
    $r->mark_ipc_disabled;
    is($r->ipc_disabled, 1, 'set to 1 after mark_ipc_disabled');
};

subtest '_artifact_monitor_entries returns key-value pairs' => sub {
    my $r = App::Yath2::Renderer2::Base->new(
        log         => undef,
        parent_pid  => $$,
        command_pid => $$,
        out_fh      => \*STDOUT,
    );
    my $m1 = bless {}, 'TestMonitor';
    my $m2 = bless {}, 'TestMonitor';
    $r->add_artifact_monitor('k1', $m1);
    $r->add_artifact_monitor('k2', $m2);
    my %entries = $r->_artifact_monitor_entries;
    is(scalar keys %entries, 2,   'two entries returned');
    is($entries{k1},         $m1, 'k1 maps to m1');
    is($entries{k2},         $m2, 'k2 maps to m2');
};

done_testing;
