use Test2::V0;
use File::Temp qw/tempdir/;
use Config;

use Test2::Harness2::Util::JSON qw/decode_json/;
use Test2::Harness2::Collector;
use Test2::Harness2::Collector::Test;
use Test2::Harness2::Collector::Logger::JSONL;
use Test2::Harness2::Event;

# Minimal observer that consumes the role, records every event it
# sees, and synthesizes one annotation event of its own for each
# incoming event. Used to verify the observer slot, instantiation,
# startup/shutdown hooks, and the collector-level appender semantic.
{

    package T2H2_RecordingObserver;
    use Object::HashBase qw{
        <run_id
        <job_id
        <job_try
        <ipcm_info
        <auditor
        <seen
        <startup_called
        <shutdown_called
    };
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Collector::Observer';

    sub init {
        my $self = shift;
        $self->{seen}            //= [];
        $self->{startup_called}  //= 0;
        $self->{shutdown_called} //= 0;
    }

    sub set_process_info {
        my ($self, %info) = @_;
        $self->{run_id}  = $info{run_id}  if exists $info{run_id};
        $self->{job_id}  = $info{job_id}  if exists $info{job_id};
        $self->{job_try} = $info{job_try} if exists $info{job_try};
    }
    sub set_ipcm_info { $_[0]->{ipcm_info} = $_[1] }
    sub set_auditor   { $_[0]->{auditor}   = $_[1] }

    sub startup  { $_[0]->{startup_called}++ }
    sub shutdown { $_[0]->{shutdown_called}++ }

    sub observe_event {
        my ($self, $event) = @_;
        push @{$self->{seen}} => $event;
        return (
            $event,
            Test2::Harness2::Event->new(
                event_id   => "synth-" . (0 + @{$self->{seen}}),
                stamp      => 0,
                facet_data => {info => [{tag => 'OBSERVER', details => 'synth'}]},
            ),
        );
    }
}

# Silence the IPC bus as Collector.t does, so unit tests don't need a
# real IPC::Manager.
BEGIN {
    require IPC::Manager;
    no warnings 'once', 'redefine';
    *IPC::Manager::connect           = sub { bless {}, 'T2H2_ObsNoopClient' };
    *T2H2_ObsNoopClient::send_message = sub { };
    *T2H2_ObsNoopClient::peer_active  = sub { 1 };
    *T2H2_ObsNoopClient::disconnect   = sub { };
}

my $CAN_FORK = $Config{d_fork};

skip_all("fork required") unless $CAN_FORK;

my $tmpdir = tempdir(CLEANUP => 1);

subtest 'role contract' => sub {
    ok(
        Role::Tiny::does_role('T2H2_RecordingObserver', 'Test2::Harness2::Role::Collector::Observer'),
        "recording observer consumes the Observer role",
    );

    my $obs = T2H2_RecordingObserver->new(ipcm_info => {});
    can_ok($obs, qw/observe_event startup shutdown set_process_info set_ipcm_info set_auditor/);

    $obs->set_process_info(run_id => 'R', job_id => 'J', job_try => 2);
    is($obs->run_id,  'R', 'set_process_info run_id');
    is($obs->job_id,  'J', 'set_process_info job_id');
    is($obs->job_try, 2,   'set_process_info job_try');

    $obs->set_ipcm_info({foo => 1});
    is($obs->ipcm_info, {foo => 1}, 'set_ipcm_info stored');
};

subtest 'observer wired into collector pipeline' => sub {
    my $output = "$tmpdir/observer.jsonl";

    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => 'test-peer',
        ipc_harness => 'test-peer',
        ipcm_info   => {},
        launch      => ['perl', '-e', 'print "hi\n"'],
        loggers     => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
        observers   => ['T2H2_RecordingObserver'],
    );

    ok($collector, "spawned collector with observer");

    my $exit = $collector->wait();
    is($exit, 0, "collector exited cleanly");

    open(my $fh, '<', $output) or die "Could not open $output: $!";
    my @events;
    while (my $line = <$fh>) {
        chomp $line;
        push @events => decode_json($line);
    }
    close($fh);

    my @synth = grep {
        my $info = $_->{facet_data}{info};
        $info && ref($info) eq 'ARRAY' && grep { $_->{tag} && $_->{tag} eq 'OBSERVER' } @$info;
    } @events;

    ok(@synth, "observer-synthesized events reached the logger");

    my @hi = grep {
        my $fd = $_->{facet_data};
        my $fs = $fd->{from_stream};
        $fs && ($fs->{source} // '') eq 'STDOUT';
    } @events;

    ok(@hi, "original stdout event still present in logger stream (pass-through)");
};

subtest 'auditor + observer startup/shutdown events reach loggers' => sub {
    # Custom auditor that consumes the Auditor role and emits one event
    # from startup and one from shutdown. The event IDs carry a tag so
    # we can assert them in the logger's output below.
    {

        package T2H2_RecAuditor;
        use Object::HashBase qw{<ipcm_info <fail_count <pass_count};
        use Role::Tiny::With;
        with 'Test2::Harness2::Role::Auditor';

        sub init {
            my $self = shift;
            $self->{fail_count} //= 0;
            $self->{pass_count} //= 0;
        }
        sub audit_event { shift; return @_ }

        sub startup {
            return Test2::Harness2::Event->new(
                event_id   => 'auditor-startup',
                stamp      => 0,
                facet_data => {info => [{tag => 'AUDITOR_STARTUP'}]},
            );
        }

        sub shutdown {
            return Test2::Harness2::Event->new(
                event_id   => 'auditor-shutdown',
                stamp      => 0,
                facet_data => {info => [{tag => 'AUDITOR_SHUTDOWN'}]},
            );
        }
    }

    # Observer that emits one startup event, one shutdown event, and
    # synthesizes one extra event for every incoming observe_event so
    # we can verify that auditor startup/shutdown events did flow
    # through the observer chain.
    {

        package T2H2_RecObserver;
        use Object::HashBase qw{<ipcm_info};
        use Role::Tiny::With;
        with 'Test2::Harness2::Role::Collector::Observer';

        our $SYN_N = 0;

        sub observe_event {
            my ($self, $event) = @_;
            return (
                $event,
                Test2::Harness2::Event->new(
                    event_id   => 'obs-synth-' . ++$SYN_N,
                    stamp      => 0,
                    facet_data => {info => [{tag => 'OBSERVER_SYNTH'}]},
                ),
            );
        }

        sub startup {
            return Test2::Harness2::Event->new(
                event_id   => 'observer-startup',
                stamp      => 0,
                facet_data => {info => [{tag => 'OBSERVER_STARTUP'}]},
            );
        }

        sub shutdown {
            return Test2::Harness2::Event->new(
                event_id   => 'observer-shutdown',
                stamp      => 0,
                facet_data => {info => [{tag => 'OBSERVER_SHUTDOWN'}]},
            );
        }
    }

    my $output = "$tmpdir/lifecycle.jsonl";

    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => 'test-peer',
        ipc_harness => 'test-peer',
        ipcm_info   => {},
        launch      => ['perl', '-e', '1'],
        auditor     => ['T2H2_RecAuditor'],
        observers   => ['T2H2_RecObserver'],
        loggers     => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
    );
    my $exit = $collector->wait();
    is($exit, 0, 'collector exited cleanly');

    open(my $fh, '<', $output) or die "open $output: $!";
    my @events;
    while (my $line = <$fh>) {
        chomp $line;
        push @events => decode_json($line);
    }
    close($fh);

    my %tag_count;
    for my $e (@events) {
        my $info = $e->{facet_data}{info};
        next unless $info && ref($info) eq 'ARRAY';
        for my $i (@$info) {
            next unless $i->{tag};
            $tag_count{$i->{tag}}++;
        }
    }

    ok($tag_count{AUDITOR_STARTUP},   'auditor startup event reached logger');
    ok($tag_count{OBSERVER_STARTUP},  'observer startup event reached logger');
    ok($tag_count{AUDITOR_SHUTDOWN},  'auditor shutdown event reached logger');
    ok($tag_count{OBSERVER_SHUTDOWN}, 'observer shutdown event reached logger');

    # Auditor startup + shutdown each fired through the observer's
    # observe_event, so at least two synth events are expected from
    # those two alone (the exit-event synth counts too but we only
    # need a floor here).
    ok(
        ($tag_count{OBSERVER_SYNTH} // 0) >= 2,
        'auditor lifecycle events flowed through the observer chain',
    );
};

done_testing;
