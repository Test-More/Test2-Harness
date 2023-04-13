package Test2::Harness::Collector;
use strict;
use warnings;

use Carp qw/croak cluck/;
use POSIX ":sys_wait_h";
use Time::HiRes qw/sleep time/;
use Scalar::Util qw/reftype/;

use Test2::Harness::Util qw/parse_exit apply_encoding/;
use Test2::Harness::Util::IPC qw/swap_io/;
use Test2::Harness::Util::JSON qw/decode_json encode_json/;

use Scope::Guard;
use Atomic::Pipe;

our $VERSION = '2.000000';

use Test2::Harness::Util::HashBase qw{
    event_cb
    merge_outputs
    buffer
    state
    children
};

sub init {
    my $self = shift;

    croak "'state' is a required attribute"
        unless $self->{+STATE};

    croak "'event_cb' is a required attribute"
        unless $self->{+EVENT_CB};

    my $type = reftype($self->{+EVENT_CB}) // '';
    croak "'event_cb' must be a coderef, got '$self->{+EVENT_CB}'"
        unless $type eq 'CODE';

    $self->{+CHILDREN}      //= {};
    $self->{+MERGE_OUTPUTS} //= 0;
}

sub DESTROY {
    my $self = shift;

    return unless $self->{+CHILDREN};
    for my $pid (keys %{$self->{+CHILDREN}}) {
        next unless $$ == $self->{+CHILDREN}->{$pid};
        cluck("Failed to reap children parent process $$ when collector instance was destroyed");
        return $self->reap;
    }
}

sub reap {
    my $self = shift;
    my (@pids) = @_;

    unless (@pids) {
        @pids = grep {$$ == $self->{+CHILDREN}->{$_}} keys %{$self->{+CHILDREN} // {}};
    }
    return unless @pids;

    my @out;

    for my $pid (@pids) {
        croak "$pid is not owned by this collector"
            unless $self->{+CHILDREN}->{$pid} && $$ == $self->{+CHILDREN}->{$pid};

        delete $self->{+CHILDREN}->{$pid};

        my $check = waitpid($pid, 0);
        my $exit = parse_exit($? // 0);
        if ($check == $pid) {
            push @out => $exit;
            warn "Collector exited with a non-zero status (ERR: $exit->{err}, SIG: $exit->{sig})" if $exit->{all};
            $self->{+STATE}->transaction(
                w => sub {
                    my ($state, $data) = @_;
                    delete $data->processes->{$pid};
                }
            );
        }
        else {
            die("waitpid returned $check");
        }
    }

    return @out;
}

sub _warn {
    my $self = shift;
    my ($msg) = @_;

    my @caller = caller();
    $msg .= " at $caller[1] line $caller[2].\n" unless $msg =~ m/\n$/;

    my $cb = $self->{+EVENT_CB};
    $self->_pre_event(frame => \@caller, facets => {info => [{tag => 'WARNING', details => $msg, debug => 1}]});
}

sub _die {
    my $self = shift;
    my ($msg) = @_;

    my @caller = caller();
    $msg .= " at $caller[1] line $caller[2].\n" unless $msg =~ m/\n$/;

    $self->_pre_event(frame => \@caller, facets => {errors => [{tag => 'ERROR', details => $msg, fail => 1}]});

    exit(255);
}

sub run {
    my $self = shift;
    my %params = @_;

    my $name       = $params{name}      or croak "'name' is a required argument";
    my $type       = $params{type}      or croak "'type' is a required argument";
    my $launch_cb  = $params{launch_cb} or croak "'launch_cb' is a required argument";

    my $parent = $params{parent_pid};

    if (!$parent) {
        $parent = $$;
        my $collector_pid = fork // CORE::die("Could not fork: $!");

        if ($collector_pid) {
            $self->{+CHILDREN}->{$collector_pid} = $$;
            return $collector_pid;
        }
    }

    $self->{+STATE}->transaction(w => sub {
        my ($state, $data) = @_;
        $data->processes->{$$} = {type => 'collector', parent => $parent, pid => $$, name => $name};
    });

    my ($out_r, $out_w) = Atomic::Pipe->pair(mixed_data_mode => 1);
    my ($err_r, $err_w) = $self->{+MERGE_OUTPUTS} ? ($out_r, $out_w) : Atomic::Pipe->pair(mixed_data_mode => 1);

    my $child_pid = fork // CORE::die("Could not fork: $!");

    if (!$child_pid) {
        swap_io(\*STDOUT, $out_w->wh, sub { $self->_die(@_) });
        swap_io(\*STDERR, $err_w->wh, sub { $self->_die(@_) });

        $ENV{T2_HARNESS_USE_ATOMIC_PIPE} = $self->{+MERGE_OUTPUTS} ? 1 : 2;
        {
            no warnings 'once';
            $Test2::Harness::STDOUT_APIPE = $out_w;
            $Test2::Harness::STDERR_APIPE = $err_w unless $self->{+MERGE_OUTPUTS};
        }

        eval { $launch_cb->(); 1 } or $self->_die($@ // "launch exception");

        $self->_die("launch-cb returned, it should not do that!");
    }

    $self->_die("Failed to launch child '$type': '$name'") unless $child_pid;

    $self->{+CHILDREN}->{$child_pid} = $$;

    $self->{+STATE}->transaction(w => sub {
        my ($state, $data) = @_;
        $data->processes->{$$}->{children}->{$child_pid} = $child_pid;
        $data->processes->{$child_pid} = {type => $type, parent => $$, pid => $child_pid, name => $name};
    });

    $self->_die("Did not get a PID from launch callback (Did callback fail to exit when done?)")
        unless $child_pid;

    my $stamp = time;
    $self->_pre_event(stamp => $stamp, frame => [__PACKAGE__, __FILE__, __LINE__], process_launch => $child_pid);

    $SIG{INT} = sub {
        $self->_warn("$$: Got SIGINT, forwarding to child process $child_pid.\n");
        kill('INT', $child_pid);
        $SIG{INT} = 'DEFAULT';
    };
    $SIG{TERM} = sub {
        $self->_warn("$$: Got SIGTERM, forwarding to child process $child_pid.\n");
        kill('TERM', $child_pid);
        $SIG{TERM} = 'DEFAULT';
    };
    $SIG{PIPE} = 'IGNORE';

    my $guard = Scope::Guard->new(sub {
        eval { $self->_die("Scope Leak inside collector post-fork!") };
        exit(255);
    });

    $out_w->close;
    $err_w->close;

    unless (eval { $self->_run(pid => $child_pid, stdout => $out_r, stderr => $err_r); 1 }) {
        my $err = $@;
        eval {
            $guard->dismiss();
            $self->_die($err);
        };
        exit(255);
    }

    $guard->dismiss();
    exit(0);
}

sub _run {
    my $self = shift;
    my %params = @_;

    $self->{+BUFFER} = {seen => {}, stderr => [], stdout => []};

    my $pid    = $params{pid};
    my $stdout = $params{stdout};
    my $stderr = $params{stderr};

    $stdout->blocking(0);
    $stderr->blocking(0);

    my @sets = (['stdout', $stdout]);
    push @sets => ['stderr', $stderr] unless $self->{+MERGE_OUTPUTS};

    my ($exited, $exit);
    while (1) {
        my $did_work = 0;

        unless ($exited) {
            if (my $check = waitpid($pid, WNOHANG)) {
                $exit = parse_exit($? // 0);

                delete $self->{+CHILDREN}->{$pid};
                if ($check == $pid) {
                    $exited = time;
                    $did_work++;

                    $self->{+STATE}->transaction(w => sub {
                        my ($state, $data) = @_;
                        delete $data->processes->{$$}->{children}->{$pid};
                        delete $data->processes->{$pid};
                    });
                }
                else {
                    die("waitpid returned $check");
                }
            }
        }

        my $enc;

        for my $set (@sets) {
            my ($name, $fh) = @$set;

            my ($type, $val) = $fh->get_line_burst_or_data;
            last unless $type;
            $did_work++;

            if ($type eq 'message') {
                my $decoded = decode_json($val);
                $self->_add_item($name => $decoded);
            }
            elsif ($type eq 'line') {
                chomp($val);
                $self->_add_item($name => $val);
            }
            else {
                chomp($val);
                die("Invalid type '$type': $val");
            }
        }

        next if $did_work;
        last if $exited;

        sleep(0.02);
    }

    $self->_flush();

    $self->_pre_event(stamp => $exited, frame => [__PACKAGE__, __FILE__, __LINE__], process_exit => $exit);

    return;
}

sub _add_item {
    my $self = shift;
    my ($stream, $val) = @_;

    my $buffer = $self->{+BUFFER} //= {};
    my $seen   = $buffer->{seen}  //= {};

    push @{$buffer->{$stream}} => $val;

    $self->_flush() unless keys(%$seen);

    return unless ref($val);

    my $event_id = $val->{event_id} or die "Event has no ID!";

    my $count = ++($seen->{$event_id});
    return unless $count >= ($self->{+MERGE_OUTPUTS} ? 1 : 2);

    $self->_flush(to => $event_id);
}

sub _flush {
    my $self = shift;
    my %params = @_;

    my $to = $params{to};

    my $buffer = $self->{+BUFFER} //= {};
    my $seen   = $buffer->{seen}  //= {};

    for my $stream (qw/stderr stdout/) {
        while (1) {
            my $val = shift(@{$buffer->{$stream}}) or last;
            if (ref($val)) {
                # Send the event, unless it came via STDERR in which case it should only be a hashref with an event_id
                $self->_pre_event(stream => $stream, data => $val)
                    unless $stream eq 'stderr';

                last if $to && $val->{event_id} eq $to;
            }
            else {
                $self->_pre_event(stream => $stream, line => $val);
            }
        }
    }
}

sub _pre_event {
    my $self = shift;
    my (%data) = @_;

    $data{stamp} //= time;

    my $cb = $self->{+EVENT_CB};
    $self->$cb(\%data);
}

1;
