package Test2::Harness::Overseer;
use strict;
use warnings;

our $VERSION = '1.000043';

use Carp qw/croak longmess/;
use POSIX qw/:sys_wait_h/;
use Fcntl qw/SEEK_CUR/;
use Time::HiRes qw/time sleep/;
use Scalar::Util qw/blessed/;
use Atomic::Pipe;
use IO::Poll qw/POLLIN POLLOUT/;
use bytes();

BEGIN { *_poll = IO::Poll->can('_poll') or die "Could not import _poll" };

use Test2::Harness::Util::IPC qw/USE_P_GROUPS/;

use Test2::Harness::Overseer::Muxer;
use Test2::Harness::Overseer::Auditor;

use Test2::Harness::Util::HashBase qw{
    <run_id
    <job_id
    <job_try
    <job

    +write
    <input_pipes

    <output
    <output_pipe

    <master_pid
    <child_pid

    <muxer          <muxer_class
    <auditor        <auditor_class
    <recorder

    <event_timeout

    <child_exited
    <child_exited_muxed

    <last_event

    +signal

    <start_stamp
};

sub init {
    my $self = shift;

    $self->{+START_STAMP} //= time;

    croak "'run_id' is a required attribute"      unless $self->{+RUN_ID};
    croak "'job' is a required attribute"         unless $self->{+JOB};
    croak "'job_id' is a required attribute"      unless $self->{+JOB_ID};
    croak "'job_try' is a required attribute"     unless defined $self->{+JOB_TRY};
    croak "'child_pid' is a required attribute"   unless $self->{+CHILD_PID};
    croak "'write' is a required attribute"       unless $self->{+WRITE};
    croak "'input_pipes' is a required attribute" unless $self->{+INPUT_PIPES};

    for my $p (values %{$self->{+INPUT_PIPES}}) {
        $p = Atomic::Pipe->from_fh('<&=', $p) unless blessed($p) && $p->isa('Atomic::Pipe');
        $p->set_mixed_data_mode();
    }

    if (my $o = $self->{+OUTPUT_PIPE}) {
        my $sigpipe = 0;
        my $ok = eval {
            local $SIG{PIPE} = sub { $sigpipe = 1; die "sigpipe" };
            $o = Atomic::Pipe->from_fh('>&=', $o) unless blessed($o) && $o->isa('Atomic::Pipe');
            $o->blocking(0);
            $self->{+OUTPUT_PIPE} = $o;

            my $output = $self->{+OUTPUT};
            if (defined $output && bytes::length($output)) {
                $o->write_burst(bytes::substr($output, 0, $o->PIPE_BUF, '')) while bytes::length($output);
            }

            $self->close_output unless $o->pending_output;

            1;
        };
        die $@ unless $ok || $sigpipe;
    }

    my @args = (
        JOB()     => $self->{+JOB},
        JOB_ID()  => $self->{+JOB_ID},
        JOB_TRY() => $self->{+JOB_TRY},
        RUN_ID()  => $self->{+RUN_ID},
        WRITE()   => $self->{+WRITE},
    );

    my $auditor_class = $self->{+AUDITOR_CLASS} //= 'Test2::Harness::Overseer::Auditor';
    $self->{+AUDITOR} = $auditor_class->new(@args);

    my $muxer_class = $self->{+MUXER_CLASS} //= 'Test2::Harness::Overseer::Muxer';
    $self->{+MUXER} = $muxer_class->new(@args, auditor => $self->{+AUDITOR});

    return;
}

sub close_output {
    my $self = shift;

    my $o = $self->{+OUTPUT_PIPE} or return;

    delete $o->{out_buffer};

    $o->close;
    $o = undef;
    delete $self->{+OUTPUT_PIPE};
    delete $self->{+OUTPUT};
}

sub watch {
    my $self = shift;

    # Write out a job start event
    $self->{+MUXER}->start($self->{+JOB}, $self->{+START_STAMP});

    # This process (overseer) should ONLY ever have 1 child process, the one we
    # care about.
    local $SIG{__WARN__} = sub {
        my ($msg) = @_;
        my $mess = $msg . longmess('Trace:');
        local $@;
        eval { $self->{+MUXER}->warning($mess) };
        warn $mess;
    };

    local $SIG{CHLD} = sub { $self->wait(fatal => 1) };
    local $SIG{TERM} = sub { $self->signal('TERM') };
    local $SIG{INT}  = sub { $self->signal('INT') };

    # In case the sigchld already happened
    $self->wait(fatal => 0, inject => {early_exit => 1});

    unless (eval { $self->watch_loop(); 1 }) {
        my $error = $@;
        eval {
            my $muxer = $self->{+MUXER};

            $muxer->audit_gen_harness_event(
                harness => {stream_error => 1, from_stream => 'harness'},
                errors  => [{
                    fail    => 1,
                    tag     => 'HARNESS',
                    details => "Internal Error: $error",
                }],
            );

            $muxer->flush();

            $self->kill_child('internal_error');
        };
    }

    $SIG{CHLD} = 'DEFAULT';
    $self->wait(block => 1, fatal => 1) unless $self->{+CHILD_EXITED};
    unless ($self->{+CHILD_EXITED_MUXED}) {
        if (my $child_exited = $self->{+CHILD_EXITED}) {
            $self->{+MUXER}->exit($child_exited);
        }
        else {
            my $retry = $self->{+JOB_TRY} < $self->{+JOB}->retry ? 'will-retry' : '';
            $self->{+MUXER}->exit({
                stamp    => time,
                wstat    => 1,
                childpid => $self->{+CHILD_PID},
                waitpid  => -1,
                retry    => $retry,
                error    => "Failed to wait on child process!",
            });
        }
    }

    $self->close_output;

    $self->{+MUXER}->finish();
    $self->{+AUDITOR}->finish();

    return;
}

sub watch_loop {
    my $self = shift;
    my $pipes = $self->{+INPUT_PIPES};

    while (keys %$pipes && !$self->{+CHILD_EXITED}) {
        my @args = map {(fileno($_->rh), POLLIN)} values %$pipes;

        my $o = $self->{+OUTPUT_PIPE};
        push @args => (fileno($o->wh), POLLOUT) if $o;

        my $poll = _poll(1000, @args);

        return unless $self->event_loop($poll);

        if (my $eto = $self->{+EVENT_TIMEOUT}) {
            my $timeout_check = time - $self->{+LAST_EVENT};
            $self->kill_child(timeout => ('event', $timeout_check)) if $timeout_check >= $eto;
            return;
        }
    }
}

my $counter = 0;
sub event_loop {
    my $self = shift;
    my ($poll) = @_;

    my $count = 0;
    while (1) {
        # Always check for and handle a child exit
        unless ($self->{+CHILD_EXITED_MUXED}) {
            if (my $child_exited = $self->{+CHILD_EXITED}) {
                $self->close_output;
                $self->{+LAST_EVENT} = time;
                $self->{+MUXER}->exit($child_exited);
                $self->{+CHILD_EXITED_MUXED} = 1;
            }
        }

        if (my $o = $self->{+OUTPUT_PIPE}) {
            my $sigpipe = 0;
            my $ok = eval {
                local $SIG{PIPE} = sub { $sigpipe = 1; die "sigpipe" };
                $o->flush;
                $self->close_output unless $o->pending_output;
                1;
            };
            unless ($ok) {
                if ($sigpipe) {
                    $self->close_output
                }
                else {
                    die $@;
                }
            }
        }

        # If we have a master process, periodically check if it has gone away,
        # starting on the first loop and doing it again every 100 iterations.
        # 100 was picked fairly arbitrarily. Slow tests will enter and leave
        # this loop at least once every second, so doing it the first iteration
        # is sufficient there. really fast tests that do not leave this loop
        # until things are done probably produce more than 100 events per
        # second so this could still be very frequent, but the performance is
        # really not an issue, I just do not want to call kill() constantly.
        # This is really just a check to make sure we stop tests if the person
        # running them contrl+c'd the harness.
        if ($self->{+MASTER_PID} && !($count++ % 100) && !kill(0, $self->{+MASTER_PID})) {
            $self->kill_child(lost_master => $self->{+MASTER_PID});
            return 0;
        }

        # -1 means signal (probably child exit).
        # 1+ means things are waiting for sure.
        # 0  means no soup for you.
        my $events = $poll ? $self->read_pipes() : 0;

        return 1 unless $events;
    }

    return 1; # unreachable?
}

sub read_pipes {
    my $self = shift;

    my $pipes = $self->{+INPUT_PIPES};

    my $events = 0;

    for my $name (keys %$pipes) {
        my $p = $pipes->{$name};

        my ($type, $data) = $p->get_line_burst_or_data;

        if ($type) {
            $events++;
            $self->{+MUXER}->process($name, $type, $data);
            $self->{+LAST_EVENT} = time;
        }
        elsif ($p->eof) {
            delete $pipes->{$name};    # Out of events for good
        }
    }

    return $events;
}

sub kill_child {
    my $self = shift;
    my ($mux_meth, @mux_args) = @_;

    my $sig = 'TERM';
    $self->{+MUXER}->$mux_meth(@mux_args, $sig);

    $sig = "-$sig" if USE_P_GROUPS;
    kill($sig, $self->{+CHILD_PID}) or return;

    # Wait for SIGCHLD or 5 seconds
    sleep 5;

    return if $self->{+CHILD_EXITED};

    $sig = 'KILL';
    $self->{+MUXER}->$mux_meth(@mux_args, $sig);

    $sig = "-$sig" if USE_P_GROUPS;
    kill($sig, $self->{+CHILD_PID});
}

sub wait {
    my $self = shift;
    my (%params) = @_;

    return if $self->{+CHILD_EXITED};

    my $check = waitpid($self->{+CHILD_PID}, $params{block} ? 0 : WNOHANG);
    my $exit = $?;

    # $check == 0 means the child is still running, if fatal is not set we simply return.
    # fatal being true means we got a signal and 0 means some other process
    # exited, that should not be possible in an overseer.
    return if $check == 0 && !$params{fatal};

    $SIG{CHLD} = 'DEFAULT';

    my $retry = $self->{+JOB_TRY} < $self->{+JOB}->retry ? 'will-retry' : '';

    my $event_data = {
        %{$params{inject} // {}},
        stamp    => time,
        wstat    => $exit,
        childpid => $self->{+CHILD_PID},
        waitpid  => $check,
        retry    => $retry,
    };

    $event_data->{error} = "Could not wait on process!"
        unless $check == $self->{+CHILD_PID};

    $self->{+CHILD_EXITED} = $event_data;

    return;
}

sub signal {
    my $self = shift;
    my ($sig) = @_;

    $self->{+SIGNAL} = {sig => $sig, stamp => time};

    $self->{+MUXER}->signal($self->{+SIGNAL});

    my $ssig = USE_P_GROUPS ? "-$sig" : $sig;
    kill($ssig, $self->{+CHILD_PID}) or warn "Could not forward signal ($ssig) to child ($self->{+CHILD_PID}): $!";

    # If we get the signal again use the default handler.
    $SIG{$sig} = 'DEFAULT';

    return;
}

1;
