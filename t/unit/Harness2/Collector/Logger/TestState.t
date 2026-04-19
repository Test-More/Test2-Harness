use Test2::V0;
use Scalar::Util qw/isweak/;

use Test2::Harness2::Collector::Logger::TestState;
use Test2::Harness2::Collector::Logger::JSONL;

my $CLASS = 'Test2::Harness2::Collector::Logger::TestState';

# ---------------------------------------------------------------------------
# Minimal auditor fake -- only the methods TestState actually reads.
# ---------------------------------------------------------------------------
{
    package T2H2_Test_FakeAuditor;
    use Object::HashBase qw{
        pass_count fail_count assertion_count
        passing_subtests failing_subtests
        exit has_exit
    };
    sub failing { $_[0]->{fail_count} ? 1 : 0 }
}

sub fake_auditor { T2H2_Test_FakeAuditor->new(@_) }

# ---------------------------------------------------------------------------
# Intercept IPC::Manager::Service::Handle so _send records to an array.
# ---------------------------------------------------------------------------
my @sent;
sub reset_sent { @sent = () }

BEGIN {
    no warnings 'once', 'redefine';
    my $fake_client = bless {}, 'T2H2_Test_FakeClient';
    *T2H2_Test_FakeClient::send_message = sub {
        my ($self, $to, $payload) = @_;
        push @sent => {to => $to, payload => $payload};
        return;
    };
    my $fake_handle = bless {}, 'T2H2_Test_FakeHandle';
    *T2H2_Test_FakeHandle::client = sub { $fake_client };

    *IPC::Manager::Service::Handle::new = sub { $fake_handle };
}

sub build_logger {
    my %overrides = @_;

    my $state = $CLASS->new(
        ipcm_info     => {fake => 1},
        peer          => 'harness',
        test_file     => 't/foo.t',
        test_file_abs => '/abs/t/foo.t',
        run_id        => 'R',
        job_id        => 'J',
        job_try       => 0,
        %overrides,
    );

    return $state;
}

subtest 'construction - required attributes' => sub {
    like(
        dies { $CLASS->new(peer => 'x') },
        qr/ipcm_info.*required/,
        'ipcm_info required',
    );
    like(
        dies { $CLASS->new(ipcm_info => {}) },
        qr/peer.*required/,
        'peer required',
    );
    like(
        dies { $CLASS->new(ipcm_info => {}, peer => 'x') },
        qr/job_id.*required/,
        'job_id required',
    );

    my $logger = $CLASS->new(
        ipcm_info => {fake => 1},
        peer      => 'harness',
        job_id    => 'J',
    );
    ok($logger, 'constructs with ipcm_info + peer + job_id');
    is($logger->job_try, 0, 'job_try defaults to 0');
};

subtest 'log_events returns false' => sub {
    my $logger = build_logger();
    ok(!$logger->log_events, 'log_events is false, no per-event loop');
};

subtest 'depends_on is empty (JSONL is optional)' => sub {
    my @deps = $CLASS->depends_on;
    is(\@deps, [], 'no required deps');
};

subtest 'startup requires an auditor' => sub {
    reset_sent;
    my $state = build_logger();
    like(
        dies { $state->startup },
        qr/requires an auditor/,
        'startup croaks without auditor',
    );
};

subtest 'startup works without a JSONL logger (log_file => undef)' => sub {
    reset_sent;
    my $state = build_logger();
    $state->set_auditor(fake_auditor());
    $state->set_loggers_lookup({});    # no JSONL

    $state->startup;
    is(scalar @sent, 1, 'one message');
    is(
        $sent[0]{payload},
        {
            kind          => 'test_started',
            test_file     => 't/foo.t',
            test_file_abs => '/abs/t/foo.t',
            log_file      => undef,
            run_id        => 'R',
            job_id        => 'J',
            job_try       => 0,
        },
        'test_started with log_file => undef',
    );
};

subtest 'startup picks up JSONL log_file when present' => sub {
    reset_sent;
    my $jsonl = Test2::Harness2::Collector::Logger::JSONL->new(
        ipcm_info   => {fake => 1},
        output_file => '/tmp/run.jsonl',
    );

    # Collector-owned strong reference; logger weakens its own copy.
    my $lookup = {ref($jsonl) => [$jsonl]};

    my $state = build_logger();
    $state->set_auditor(fake_auditor());
    $state->set_loggers_lookup($lookup);

    $state->startup;
    is($sent[0]{payload}{log_file}, '/tmp/run.jsonl', 'log_file picked up');
};

subtest 'startup uses the first JSONL when multiple are present' => sub {
    reset_sent;
    my $first = Test2::Harness2::Collector::Logger::JSONL->new(
        ipcm_info => {fake => 1}, output_file => '/tmp/first.jsonl',
    );
    my $second = Test2::Harness2::Collector::Logger::JSONL->new(
        ipcm_info => {fake => 1}, output_file => '/tmp/second.jsonl',
    );

    my $lookup = {ref($first) => [$first, $second]};

    my $state = build_logger();
    $state->set_auditor(fake_auditor());
    $state->set_loggers_lookup($lookup);

    $state->startup;
    is($sent[0]{payload}{log_file}, '/tmp/first.jsonl', 'first JSONL is used');
};

subtest 'set_loggers_lookup weakens the stored reference' => sub {
    my $state = build_logger();

    # Hold the hashref by a scoped strong reference so it does not die
    # immediately under weaken.
    my $lookup = {};
    $state->set_loggers_lookup($lookup);
    ok(isweak($state->{loggers_lookup}), 'stored reference is weak');

    # When the outer strong reference goes away, the weakened one follows.
    undef $lookup;
    ok(!defined $state->{loggers_lookup}, 'weak ref is undef after collector drops lookup');
};

subtest 'loggers_lookup passed via constructor is weakened too' => sub {
    my $lookup = {};
    my $state  = $CLASS->new(
        ipcm_info      => {fake => 1},
        peer           => 'harness',
        job_id         => 'J',
        loggers_lookup => $lookup,
    );
    ok(isweak($state->{loggers_lookup}),
        'constructor-supplied lookup is weakened in init');
    undef $lookup;
    ok(!defined $state->{loggers_lookup},
        'weak ref follows the outer strong ref going away');
};

subtest 'failing() sends test_failing' => sub {
    reset_sent;
    my $state = build_logger();
    $state->set_auditor(fake_auditor());
    $state->set_loggers_lookup({});
    $state->startup;
    reset_sent;

    $state->failing(1);
    is(scalar @sent, 1, 'one message');
    is($sent[0]{payload}{kind}, 'test_failing', 'kind is test_failing');
};

subtest 'shutdown emits summary straight from the auditor' => sub {
    reset_sent;
    my $jsonl = Test2::Harness2::Collector::Logger::JSONL->new(
        ipcm_info => {fake => 1}, output_file => '/tmp/run.jsonl',
    );
    my $lookup = {ref($jsonl) => [$jsonl]};

    my $state = build_logger();
    $state->set_auditor(fake_auditor(
        pass_count       => 5,
        fail_count       => 1,
        assertion_count  => 6,
        passing_subtests => ['first',  'third'],
        failing_subtests => ['second'],
        has_exit         => 1,
        exit             => 256,
    ));
    $state->set_loggers_lookup($lookup);
    $state->startup;
    reset_sent;

    $state->shutdown;

    is(scalar @sent, 1, 'one message');
    is(
        $sent[0]{payload},
        {
            kind             => 'test_completed',
            test_file        => 't/foo.t',
            test_file_abs    => '/abs/t/foo.t',
            log_file         => '/tmp/run.jsonl',
            pass_count       => 5,
            fail_count       => 1,
            assertion_count  => 6,
            passing_subtests => ['first', 'third'],
            failing_subtests => ['second'],
            exit             => 256,
            run_id           => 'R',
            job_id           => 'J',
            job_try          => 0,
        },
        'test_completed summary',
    );
};

subtest 'shutdown defaults empty subtest lists when auditor has none' => sub {
    reset_sent;
    my $state = build_logger();
    $state->set_auditor(fake_auditor(
        pass_count => 0, fail_count => 0, assertion_count => 0,
        has_exit => 1, exit => 0,
    ));
    $state->set_loggers_lookup({});
    $state->startup;
    reset_sent;

    $state->shutdown;
    is($sent[0]{payload}{passing_subtests}, [], 'empty list default');
    is($sent[0]{payload}{failing_subtests}, [], 'empty list default');
};

subtest 'metadata is undef -- TestState has no retrievable output' => sub {
    my $state = build_logger();
    ok(!defined $state->metadata, 'metadata is undef (role default)');
};

done_testing;
