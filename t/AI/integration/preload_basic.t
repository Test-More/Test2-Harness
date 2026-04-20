use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec ();

use Test2::Util qw/CAN_REALLY_FORK/;

skip_all "preload test needs real fork"
    unless CAN_REALLY_FORK;

skip_all "preload test requires forking" if $ENV{T2_NO_FORK};

use Test2::Harness2;
use Test2::Harness2::Resource::JobCount;
use Test2::Harness2::Resource::Preload;
use App::Yath2::TestFile;
use Test2::Harness2::Test::Loggers qw/
    classic_harness_loggers
    classic_test_loggers
/;

# Simple end-to-end smoke: a harness configured with a Preload resource
# (preloading Scalar::Util as a trivially-present core module) must
# route a single trivially-passing test through the preload service
# path and report pass=1 via the normal run_status IPC query.

my $wd = tempdir(CLEANUP => 1);

# Write a tiny passing test into the workdir. Using a heredoc keeps
# the fixture self-contained.
my $test_file = File::Spec->catfile($wd, 'preload_pass.t');
open(my $fh, '>', $test_file) or die "open $test_file: $!";
print $fh <<'PERL';
use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw/blessed/;
ok(1, 'preloaded test passed');
done_testing;
PERL
close($fh) or die;

my $spawn = Test2::Harness2->spawn(
    workdir   => $wd,
    resources => [
        Test2::Harness2::Resource::JobCount->new(slots => 1),
        Test2::Harness2::Resource::Preload->new(
            workdir => $wd,
            preload => ['Scalar::Util'],
        ),
    ],
    loggers      => classic_harness_loggers($wd, 'harness'),
    test_loggers => classic_test_loggers(),
);

my $tf         = App::Yath2::TestFile->new(file => $test_file);
my $queue_resp = $spawn->queue_test_run(files => [$tf]);
my $run_id     = ref($queue_resp) eq 'HASH' ? $queue_resp->{run_id} : undef;
ok(defined $run_id, 'got a run_id') or do {
    require Data::Dumper;
    diag(Data::Dumper::Dumper($queue_resp));
};

# Poll for completion.
my $deadline = time + 30;
my $status;
while (time < $deadline) {
    $status = $spawn->run_status($run_id);
    my $state = ref($status) eq 'HASH' ? $status->{state} // '' : '';
    last if $state eq 'completed';
    last
        if $state eq 'running'
        && !@{$status->{pending} // []}
        && !@{$status->{running} // []};
    Time::HiRes::sleep(0.05);
}

ok(ref($status) eq 'HASH' && $status->{ok}, 'run_status returned ok')
    or diag explain $status;

is($status->{pass_count}, 1, 'one passing test') or diag explain $status;
is($status->{fail_count}, 0, 'no failing tests') or diag explain $status;

$spawn->finish;
{ local $?; $spawn->wait; }

# Second scenario: confirm the preloaded module is ALREADY in %INC in
# the test child. We stage a sentinel module in a tempdir, configure
# the preload to load it, and the test asserts %INC knows about it
# before the test file itself does any `use` of it.
#
# This is what 'preload' actually buys us: the test process inherits
# the preloaded interpreter's %INC via fork, so a `use` of a slow
# module is effectively free.

my $wd2 = tempdir(CLEANUP => 1);
mkdir "$wd2/prelib"                                       or die $!;
mkdir "$wd2/prelib/T2H2Preload"                           or die $!;
open(my $mfh, '>', "$wd2/prelib/T2H2Preload/Sentinel.pm") or die $!;
print $mfh <<'PERL';
package T2H2Preload::Sentinel;
our $LOADED_IN_PID = $$;
our $VALUE         = 'sentinel-was-preloaded';
1;
PERL
close($mfh) or die;

my $test_file2 = "$wd2/sentinel_check.t";
open(my $tfh2, '>', $test_file2) or die $!;
print $tfh2 <<'PERL';
use strict;
use warnings;
use Test2::V0;

ok(exists $INC{'T2H2Preload/Sentinel.pm'},
   'sentinel module was preloaded (visible in %INC at test startup)');

# We do not `use` the sentinel yet -- we only check that it's already
# in %INC. That is the signal that the preload service forked us with
# its %INC already populated.
done_testing;
PERL
close($tfh2) or die;

local $ENV{PERL5LIB} = "$wd2/prelib" . (defined $ENV{PERL5LIB} ? ":$ENV{PERL5LIB}" : '');

my $spawn2 = Test2::Harness2->spawn(
    workdir   => $wd2,
    resources => [
        Test2::Harness2::Resource::JobCount->new(slots => 1),
        Test2::Harness2::Resource::Preload->new(
            workdir => $wd2,
            preload => ['T2H2Preload::Sentinel'],
        ),
    ],
    loggers      => classic_harness_loggers($wd2, 'harness'),
    test_loggers => classic_test_loggers(),
);

my $tf2     = App::Yath2::TestFile->new(file => $test_file2);
my $qr2     = $spawn2->queue_test_run(files => [$tf2]);
my $run_id2 = ref($qr2) eq 'HASH' ? $qr2->{run_id} : undef;
ok(defined $run_id2, 'got a second run_id') or do {
    require Data::Dumper;
    diag(Data::Dumper::Dumper($qr2));
};

my $deadline2 = time + 30;
my $status2;
while (time < $deadline2) {
    $status2 = $spawn2->run_status($run_id2);
    my $s = ref($status2) eq 'HASH' ? $status2->{state} // '' : '';
    last if $s eq 'completed';
    last
        if $s eq 'running'
        && !@{$status2->{pending} // []}
        && !@{$status2->{running} // []};
    Time::HiRes::sleep(0.05);
}

ok(
    ref($status2) eq 'HASH' && $status2->{ok},
    'second run_status returned ok'
) or diag explain $status2;
is($status2->{pass_count}, 1, 'sentinel-preload test passed')
    or diag explain $status2;
is($status2->{fail_count}, 0, 'no failing tests in sentinel run')
    or diag explain $status2;

$spawn2->finish;
{ local $?; $spawn2->wait; }

done_testing;
