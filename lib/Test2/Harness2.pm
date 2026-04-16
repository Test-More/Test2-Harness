package Test2::Harness2;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Path qw/make_path/;
use Time::HiRes qw/time/;
use Test2::Util::UUID qw/gen_uuid/;

use constant HAS_LINUX_PRCTL => eval { require Linux::Prctl; 1 } ? 1 : 0;

use Test2::Harness2::Util::HashBase qw{
    <workdir
    <name
    <job_id
    <loggers
    <test_auditor
    <test_loggers
    <kill_timeout
    <parent_pids
    +state
    +queue
    +current
    +finish_after_initial_run
    +emitter
    +watch_pids_ref
};

use Role::Tiny::With;
with 'IPC::Manager::Role::Service';

sub init {
    my $self = shift;

    my $wd = $self->{+WORKDIR} // croak "'workdir' is a required attribute";
    croak "workdir '$wd' does not exist or is not a directory" unless -d $wd;
    croak "workdir '$wd' already contains services/ -- refusing to clobber"
        if -e "$wd/services";
    croak "workdir '$wd' already contains runs/ -- refusing to clobber"
        if -e "$wd/runs";

    make_path("$wd/services");

    $self->{+NAME}           //= 'harness';
    $self->{+JOB_ID}         //= gen_uuid();
    $self->{+KILL_TIMEOUT}   //= 15;
    $self->{+PARENT_PIDS}    //= [];
    $self->{+STATE}          //= 'running';
    $self->{+QUEUE}          //= [];
    $self->{+WATCH_PIDS_REF} //= [@{$self->{+PARENT_PIDS}}];

    $self->{+LOGGERS} //= [
        [
            'Test2::Harness2::Collector::Logger::JSONL',
            output_file => "$wd/services/$self->{+NAME}.jsonl",
        ],
    ];
    $self->{+TEST_AUDITOR} //= 'Test2::Harness2::Collector::Auditor::Test';
    $self->{+TEST_LOGGERS} //= ['Test2::Harness2::Collector::Logger::JSONL'];
}

# IPC::Manager::Role::Service required methods. Fleshed out in later tasks.
sub orig_io    { {} }
sub ipcm_info  { $_[0]->{ipcm_info} }
sub pid        { $_[0]->{pid} //= $$ }
sub set_pid    { $_[0]->{pid} = $_[1] }
sub watch_pids { $_[0]->{+WATCH_PIDS_REF} }

# IPC::Manager calls handle_request($req, $msg) where $req is a hashref
# with a 'request' key holding the request-name string, e.g.
# { request => 'status', ipcm_request_id => '...', ... }.
# We dispatch on $req->{request}.
sub handle_request {
    my ($self, $req, $msg) = @_;

    my $name = $req->{request};

    return $self->handle_status_request if $name eq 'status';
    # Tasks 10-12 add: queue_test_run, finish, Terminate, Detach

    return {ok => 0, error => "unknown request '$name'"};
}

sub handle_status_request {
    my $self = shift;

    my $queue = [
        map { {
            run_id  => $_->run_id,
            pending => [@{$_->pending}],
            running => [@{$_->running}],
            done    => [@{$_->done}],
        } } @{$self->{+QUEUE}}
    ];

    my $running;
    if (my $cur = $self->{+CURRENT}) {
        $running = {
            run_id    => $cur->{run}->run_id,
            job_id    => $cur->{job}->job_id,
            test_file => $cur->{job}->test_file,
            pid       => $cur->{pid},
            started   => $cur->{started_at},
        };
    }

    return {
        service => {
            name    => $self->{+NAME},
            pid     => $$,
            job_id  => $self->{+JOB_ID},
            workdir => $self->{+WORKDIR},
            state   => $self->{+STATE},
        },
        queue   => $queue,
        running => $running,
    };
}

1;

__END__

=head1 NAME

Test2::Harness2 - Top-level test harness service.

=head1 SYNOPSIS

    # Run once, then exit
    Test2::Harness2->start(
        workdir                  => '/path/to/wd',
        test_run                 => {files => ['t/a.t', 't/b.t']},
        finish_after_initial_run => 1,
    );

    # Spawn as a persistent daemon, keep queuing
    my $spawn = Test2::Harness2->spawn(workdir => '/path/to/wd');
    $spawn->queue_test_run(files => ['t/c.t']);
    my $status = $spawn->status;
    $spawn->finish;
    $spawn->wait;

=head1 DESCRIPTION

B<Use start() or spawn(), not new().> Direct C<new()> constructs the object
but does not start the service loop. Prefer the C<start()> entry point when
you want the current process to become the harness, or C<spawn()> when you
want the harness to run in a child process and get back a handle to it.

=cut
