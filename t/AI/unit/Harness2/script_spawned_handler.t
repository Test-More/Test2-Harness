use Test2::V0;
use POSIX ();
use Time::HiRes ();
use Test2::Harness2::SpawnGateway;

my $client_class = 'TSSClient';
{
    no strict 'refs';
    *{"${client_class}::send_message"} = sub { push @{$_[0]{sent}}, [@_[1,2]]; 1 };
}

# Fake harness that provides the bits SpawnGateway reaches through:
# name, client, ipcm_info. We never call the real Test2::Harness2 ctor
# in this unit test.
{
    package TSSHarness;
    sub new { my ($c, %p) = @_; bless { %p }, $c }
    sub name      { $_[0]->{name}      // 'harness' }
    sub client    { $_[0]->{client} }
    sub ipcm_info { $_[0]->{ipcm_info} // '' }
}

subtest 'handle_spawned records child pid on pending entry' => sub {
    my @sent;
    my $client = bless { sent => \@sent }, $client_class;
    my $h  = TSSHarness->new(name => 'harness', client => $client);
    my $sg = Test2::Harness2::SpawnGateway->new(harness => $h);
    $sg->{Test2::Harness2::SpawnGateway::PENDING_SCRIPT_SPAWNS()} = {
        7 => { notify_to => 'yath-spawn-9999', stage => 'BASE', preload_pid => 1234 },
    };

    $sg->handle_spawned({ kind => 'script_spawned', spawn_id => 7, pid => 55555 });

    is($sg->{Test2::Harness2::SpawnGateway::PENDING_SCRIPT_SPAWNS()}{7}{child_pid}, 55555,
        'child pid recorded');
};

subtest 'poll sends script_exited and clears pending' => sub {
    my @sent2;
    my $client2 = bless { sent => \@sent2 }, $client_class;
    my $kid = fork // die "fork: $!";
    if (!$kid) { POSIX::_exit(42) }
    Time::HiRes::sleep(0.1);

    my $h2  = TSSHarness->new(name => 'harness', client => $client2);
    my $sg2 = Test2::Harness2::SpawnGateway->new(harness => $h2);
    $sg2->{Test2::Harness2::SpawnGateway::PENDING_SCRIPT_SPAWNS()} = {
        8 => { notify_to => 'cli-1', child_pid => $kid },
    };

    $sg2->poll;

    is(scalar(@sent2), 1, 'one notification sent');
    is($sent2[0][0], 'cli-1', 'sent to notify_to');
    is($sent2[0][1]{kind}, 'script_exited', 'kind=script_exited');
    is($sent2[0][1]{exit}, 42, 'exit code forwarded');
    is($sg2->{Test2::Harness2::SpawnGateway::PENDING_SCRIPT_SPAWNS()}{8}, undef,
        'pending entry cleared');
};

subtest 'poll leaves still-running entries alone' => sub {
    my $h3  = TSSHarness->new(name => 'harness',
        client => bless { sent => [] }, $client_class);
    my $sg3 = Test2::Harness2::SpawnGateway->new(harness => $h3);
    $sg3->{Test2::Harness2::SpawnGateway::PENDING_SCRIPT_SPAWNS()} = {
        9 => { notify_to => 'cli-2', child_pid => $$ },
    };

    $sg3->poll;
    ok($sg3->{Test2::Harness2::SpawnGateway::PENDING_SCRIPT_SPAWNS()}{9}, 'still pending');
};

done_testing;
