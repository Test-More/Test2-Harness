package Test2::Harness::Util::Collector;
use strict;
use warnings;

use Carp qw/croak/;
use POSIX ":sys_wait_h";
use Time::HiRes qw/sleep time/;
use Scalar::Util qw/reftype/;

use Test2::Harness::Util qw/parse_exit/;
use Test2::Harness::Util::JSON qw/decode_json/;

use Scope::Guard;
use Atomic::Pipe;

our $VERSION = '2.000000';

use Test2::Harness::Util::HashBase qw{
    event_cb
    merge_outputs
    buffer
};

sub init {
    my $self = shift;

    croak "'event_cb' is a required attribute"
        unless $self->{+EVENT_CB};

    my $type = reftype($self->{+EVENT_CB}) // '';
    croak "'event_cb' must be a coderef, got '$self->{+EVENT_CB}'"
        unless $type eq 'CODE';

    $self->{+MERGE_OUTPUTS} //= 0;
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
    my ($launch_cb) = @_;

    my $parent = $$;
    my $pid = fork // CORE::die("Could not fork: $!");

    return $pid if $pid;

    $self->_warn("Add IPC process control for collector");

    my ($out_r, $out_w) = Atomic::Pipe->pair(mixed_data_mode => 1);
    my ($err_r, $err_w) = $self->{+MERGE_OUTPUTS} ? ($out_r, $out_w) : Atomic::Pipe->pair(mixed_data_mode => 1);

    close(STDOUT) or $self->_warn("Could not close STDOUT: $!");
    open(STDOUT, '>&', $out_w->wh) or $self->_die("Could not open STDOUT: $!");
    $self->_die("STDOUT got incorrect fileno: " . fileno(STDOUT)) unless fileno(STDOUT) == 1;

    close(STDERR) or $self->_warn("Could not close STDERR: $!");
    open(STDERR, '>&', $err_w->wh) or $self->_die("Could not open STDERR: $!");
    $self->_die("STDERR got incorrect fileno: " . fileno(STDERR)) unless fileno(STDERR) == 2;

    $ENV{T2_HARNESS_USE_ATOMIC_PIPE} = $self->{+MERGE_OUTPUTS} ? 1 : 2;
    {
        no warnings 'once';
        $Test2::Harness::STDOUT_APIPE = $out_w;
        $Test2::Harness::STDERR_APIPE = $err_w unless $self->{+MERGE_OUTPUTS};
    }

    eval { $pid = $launch_cb->(); 1 } or $self->_die($@ // "Exception from launch_cb");

    $self->_die("Did not get a PID from launch callback (Did callback fail to exit when done?)")
        unless $pid;

    my $stamp = time;
    $self->_pre_event(stamp => $stamp, frame => [__PACKAGE__, __FILE__, __LINE__], process_launch => $pid);

    $SIG{INT}  = sub {
        $self->_warn("$$: Got SIGINT, forwarding to child process $pid.\n");
        kill('INT', $pid);
        $SIG{INT} = 'DEFAULT';
    };
    $SIG{TERM} = sub {
        $self->_warn("$$: Got SIGTERM, forwarding to child process $pid.\n");
        kill('TERM', $pid);
        $SIG{TERM} = 'DEFAULT';
    };
    $SIG{PIPE} = 'IGNORE';

    $self->_warn("Add IPC process control for test job");

    my $guard = Scope::Guard->new(sub {
        eval { $self->_die("Scope Leak!") };
        exit(255);
    });

    $SIG{__WARN__} = sub { $self->_warn($_) for @_ };

    $out_w->close;
    $err_w->close;
    close(STDOUT);
    close(STDERR);

    unless (eval { $self->_run(pid => $pid, stdout => $out_r, stderr => $err_r); 1 }) {
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
                if ($check == $pid) {
                    $exited = time;
                    $did_work++;
                }
                else {
                    die("waitpid returned $check");
                }
            }
        }

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
                    unless $stream eq 'STDERR';

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
