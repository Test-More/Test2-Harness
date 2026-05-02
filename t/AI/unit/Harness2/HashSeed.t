use Test2::V0;
use File::Temp qw/tempdir/;

use lib 't/lib';
use Test2::Harness2::TestFile;

# Stub the IPC client that Test2::Harness2's IPC role might try to
# create at runtime. The unit-level subtests exercise pure-Perl
# request handlers, so a real bus isn't needed.
BEGIN {
    require IPC::Manager;
    no warnings 'once', 'redefine';
    *IPC::Manager::connect = sub {
        return bless {}, 'T2H2_HashSeedTest_NoopClient';
    };
    *T2H2_HashSeedTest_NoopClient::send_message = sub { return };
    *T2H2_HashSeedTest_NoopClient::peer_active  = sub { 1 };
    *T2H2_HashSeedTest_NoopClient::disconnect   = sub { return };
}

use Test2::Harness2;

sub _tf  { Test2::Harness2::TestFile->new(file => $_[0]) }
sub _tfs { [map { _tf($_) } @_] }

subtest 'queue_test_run propagates hash_seed onto the queued run' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $res = $h->request_handler_queue_test_run({
        files     => _tfs('t/x.t'),
        hash_seed => '20260101',
    });
    ok($res->{ok}, 'queued');

    is($h->{queue}[0]->hash_seed, '20260101', 'queued run carries seed');
};

subtest 'queue_test_run accepts a run with no seed when harness has none' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $res = $h->request_handler_queue_test_run({files => _tfs('t/x.t')});
    ok($res->{ok}, 'no-seed run accepted');
    is($h->{queue}[0]->hash_seed, undef, 'no seed on the queued run');
};

subtest 'reject mismatch: harness=A vs run=B' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir, hash_seed => '20260101');

    my $res = $h->request_handler_queue_test_run({
        files     => _tfs('t/x.t'),
        hash_seed => '20260202',
    });
    ok(!$res->{ok}, 'rejected');
    like(
        $res->{error},
        qr/--set-hash-seed=20260202 on the run does not match --set-hash-seed=20260101 on the harness/,
        'error names both seeds',
    );
    like($res->{error}, qr/preload was started with seed 20260101/, 'preload-context message present');
};

subtest 'accept: harness has seed, run does not (run inherits via env)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir, hash_seed => '20260101');

    my $res = $h->request_handler_queue_test_run({files => _tfs('t/x.t')});
    ok($res->{ok}, 'accepted');
    is($h->{queue}[0]->hash_seed, undef, 'run remained seedless');
};

subtest 'accept: run has seed, harness does not (no global preload bound)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $res = $h->request_handler_queue_test_run({
        files     => _tfs('t/x.t'),
        hash_seed => '20260101',
    });
    ok($res->{ok}, 'accepted');
    is($h->{queue}[0]->hash_seed, '20260101', 'run carries its own seed');
};

subtest 'agreement is accepted: harness=A and run=A' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir, hash_seed => '20260101');

    my $res = $h->request_handler_queue_test_run({
        files     => _tfs('t/x.t'),
        hash_seed => '20260101',
    });
    ok($res->{ok}, 'accepted on agreement');
    is($h->{queue}[0]->hash_seed, '20260101', 'seed on the run matches');
};

done_testing;
