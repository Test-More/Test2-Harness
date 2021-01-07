package Test2::Harness::Overseer::Muxer;
use strict;
use warnings;

use Test2::Util qw/ipc_separator/;
use Test2::Harness::Util qw/parse_exit/;
use Test2::Harness::Util::JSON qw/decode_json/;
use Test2::Harness::Util::UUID qw/gen_uuid/;

use Carp qw/croak/;
use Encode qw/find_encoding/;
use List::Util qw/max/;
use Time::HiRes qw/time/;

our $VERSION = '1.000043';

use parent 'Test2::Harness::Overseer::EventGen';
use Test2::Harness::Util::HashBase qw{
    <tap_parser
    <buffers
    <encoding
    <stamps
    <synced
    <auditor
};

sub init {
    my $self = shift;

    $self->SUPER::init();

    croak "'auditor' is a required attribute" unless $self->{+AUDITOR};

    unless ($self->{+TAP_PARSER}) {
        require Test2::Harness::Overseer::TapParser;
        $self->{+TAP_PARSER} = 'Test2::Harness::Overseer::TapParser';
    }

    $self->{+ENCODING} = {};
    $self->{+BUFFERS}  = {};
    $self->{+STAMPS}   = {};
    $self->{+SYNCED}   = {'SYNC ERROR' => 1};
}

sub flush {
    my $self = shift;
    my %params = @_;

    my $buffers = $self->{+BUFFERS}            //= {};
    my $stderr  = $self->{+BUFFERS}->{stderr}  //= [];
    my $stdout  = $self->{+BUFFERS}->{stdout}  //= [];

    while (@$stderr || @$stdout) {
        # Flush anything not sync-blocked
        $self->{+AUDITOR}->process(shift @$stderr) while @$stderr && ref($stderr->[0]);
        $self->{+AUDITOR}->process(shift @$stdout) while @$stdout && ref($stdout->[0]);

        # One hit a sync point, the other is empty
        last unless @$stderr && @$stdout;

        my $esync = $stderr->[0];
        my $osync = $stdout->[0];

        # Synced!
        if (defined($esync) && defined($osync) && $esync eq $osync) {
            $self->{+SYNCED}->{$esync} = 1;
            $self->{+SYNCED}->{$osync} = 1;
            shift @$stderr;
            shift @$stdout;
            next;
        }

        # Uh oh, concurrency must be messing with us.
        last unless $self->resync($stderr, $stdout);
    }

    return unless $params{all};

    $self->{+AUDITOR}->process($_) for grep { ref($_) } @$stderr, @$stdout;
    @$stderr = ();
    @$stdout = ();

    return;
}

sub resync {
    my $self = shift;
    my ($stderr, $stdout) = @_;

    # We may have already flushed past some sync points, if so move past them and do a new loop
    my @stripped;
    for my $set ($stderr, $stdout) {
        push @stripped => shift @$set while $self->{+SYNCED}->{$set->[0]};
    }
    return 1 if @stripped;

    # Ok, find the closest common-sync point
    # %seen will first be populatd by our 2 current sync points which start
    # each array. Once a sync point is noticed twice it is the next common
    # sync point, and we will flush to that next. If we find no common sync
    # point then we are not ready to flush and need to wait.
    my %seen;
    my $found;
    for (my $i = 0; $i < max(scalar(@$stderr), scalar(@$stdout)); $i++) {
        for my $set ($stderr, $stdout) {
            last unless exists $set->[$i];
            if (!ref($set->[$i]) && $seen{$set->[$i]}++) {
                $found = $set->[$i];
                last;
            }
        }

        last if $found;
    }

    # Neither has the others sync points, so we wait
    return 0 unless $found;

    # Sync everyone to the common sync point
    for my $set ($stderr, $stdout) {
        while (@$set) {
            my $e = shift @$set;
            if (ref $e) {
                $self->{+AUDITOR}->process($e);
            }
            else {
                # Record any sync point for later so we can just zoom past
                # it.
                $self->{+SYNCED}->{$e}++ unless $e eq 'SYNC ERROR';
                last if $e eq $found;
            }
        }
    }

    return 1;
}

sub audit_gen_harness_event {
    my $self = shift;
    my $e = $self->gen_harness_event(@_);
    $self->{+AUDITOR}->process($e);
}

sub stream_error {
    my $self = shift;
    my ($source, $error) = @_;

    $self->audit_gen_harness_event(
        harness => {stream_error => 1, from_stream => $source},
        errors  => [{
            fail    => 1,
            tag     => 'HARNESS',
            details => "Internal error reading from $source pipe: $error",
        }],
    );

    return $self->flush();
}

sub process {
    my $self = shift;
    my ($source, $type, $data) = @_;

    return $self->_process_line($source, $data)    if $type eq 'line';
    return $self->_process_message($source, $data) if $type eq 'message';
    return $self->stream_error($source, "Invalid data type '$type', got data:\n===\n$data\n===\n\n");
}

sub finish {
    my $self = shift;
    $self->flush(all => 1);
}

sub signal {
    my $self = shift;
    my ($sig) = @_;

    $self->audit_gen_harness_event(
        harness => {
            stamp       => $sig->{stamp},
            from_stream => 'harness',
        },
        errors => [{
            tag     => 'HARNESS',
            fail    => 1,
            details => "Harness overseer caught signal '$sig->{sig}', forwarding to test...",
        }]
    );

    return $self->flush;
}

sub start {
    my $self = shift;
    my ($job, $stamp) = @_;

    $self->audit_gen_harness_event(
        harness_job => $job,
        harness     => {
            stamp       => $stamp,
            from_stream => 'harness',
        },
        harness_job_launch => {
            stamp => $stamp,
            retry => $self->{+JOB_TRY},
        },
        harness_job_start => {
            details  => "Job $self->{+JOB_ID} started at $stamp",
            job_id   => $self->{+JOB_ID},
            stamp    => $stamp,
            file     => $job->file,
            rel_file => $job->rel_file,
            abs_file => $job->abs_file,
        },
    );

    return $self->flush;
}

sub exit {
    my $self = shift;
    my ($exit_data) = @_;

    my $wstat = parse_exit($exit_data->{wstat});
    my $stamp = $exit_data->{stamp};

    $self->audit_gen_harness_event(
        harness => {
            stamp       => $stamp,
            from_stream => 'harness',
        },
        harness_job_exit => {
            stamp   => $stamp,
            job_id  => $self->{+JOB_ID},
            job_try => $self->{+JOB_TRY},

            details => "Test script exited $wstat->{all} ($wstat->{err}\:$wstat->{sig})",

            exit    => $wstat->{all},
            code    => $wstat->{err},
            signal  => $wstat->{sig},
            dumped  => $wstat->{dmp},

            retry   => $exit_data->{retry},
        },

        $exit_data->{error} ? (
            errors => [{
                details => $exit_data->{error},
                fail => 1,
                tag => 'HARNESS',
            }],
        ) : (),
    );

    return $self->flush;
}

my %EXIT_REASONS = (
    event => <<'    EOT',
Test2::Harness checks for timeouts at a configurable interval, if a test does
not produce any output to stdout or stderr between intervals it will be
forcefully killed under the assumption it has hung. See the '--event-timeout'
option to configure the interval.
    EOT
);

sub timeout {
    my $self = shift;
    my ($type, $timeout, $sig) = @_;

    my $stamp = time;
    chomp(my $reason = $EXIT_REASONS{$type});

    $self->audit_gen_harness_event(
        harness => {
            stamp       => $stamp,
            from_stream => 'harness',
        },
        errors => [{
            details => "A timeout ($type) has occured (after $timeout seconds), job was forcefully killed with signal $sig",
            fail    => 1,
            tag     => 'TIMEOUT',
        }],
        info => [{
            tag       => 'TIMEOUT',
            debug     => 1,
            important => 1,
            details   => $reason,
        }],
    );

    return $self->flush;
}

sub internal_error {
    my $self = shift;
    my ($sig) = @_;

    $self->audit_gen_harness_event(
        harness => {
            stamp       => time,
            from_stream => 'harness',
        },
        errors => [{
            details => "An internal error has occured, job was forcefully killed with signal $sig",
            fail    => 1,
            tag     => 'HARNESS',
        }],
    );

    return $self->flush;
}

sub warning {
    my $self = shift;
    my ($msg) = @_;

    $self->audit_gen_harness_event(
        harness => {
            stamp       => time,
            from_stream => 'harness',
        },
        info => [{
            details => "Harness overseer produced a warning: $msg",
            fail    => 0,
            tag     => 'HARNESS',
        }],
    );

    return $self->flush;
}

sub lost_master {
    my $self = shift;
    my ($master_pid, $sig) = @_;

    $self->audit_gen_harness_event(
        harness => {
            stamp       => time,
            from_stream => 'harness',
        },
        errors => [{
            details => "The master process ($master_pid) went away! Killing test with signal $sig...",
            fail    => 1,
            tag     => 'HARNESS',
        }],
    );

    return $self->flush;
}

sub _process_line {
    my $self = shift;
    my ($source, $line) = @_;

    $line = $self->{+ENCODING}->{$source}->decode($line)
        if $self->{+ENCODING}->{$source};

    chomp($line);
    my $parse_meth = "parse_${source}_tap";
    my $facet_data = $self->{+TAP_PARSER}->$parse_meth($line);
    if ($facet_data) {
        $facet_data->{harness}->{from_tap} = $line;
    }
    else {
        $facet_data = {info => [{details => $line, tag => uc($source)}]};
    }

    $facet_data->{harness}->{stamp}       //= $self->{+STAMPS}->{$source} // time;
    $facet_data->{harness}->{from_stream} //= $source;
    $facet_data->{harness}->{from_line}   //= 1;
    $facet_data->{info}->[0]->{debug} = 1 if $source eq 'stderr';

    push @{$self->{+BUFFERS}->{$source}} => $self->gen_event($facet_data);
    return $self->flush();
}

sub _process_message {
    my $self = shift;
    my ($source, $message) = @_;

    my $jid = $self->{+JOB_ID};

    return $self->stream_error($source => "Invalid Atomic::Pipe message:\n===$message\n===\n")
        unless $message =~ m/^STREAM-(ESYNC|EVENT|ENCODING) (\S+) (\S+) (\S.*)\z/;
    my ($type, $job_id, $stamp, $payload) = ($1, $2, $3, $4);

    return $self->stream_error($source => "Got meta-message intended for another job (got '$job_id', expected '$jid'):\n===$message\n===\n")
        unless $jid eq $job_id;

    $self->{+STAMPS}->{$source} = $stamp;

    if ($type eq 'ESYNC') {
        push @{$self->{+BUFFERS}->{$source}} => $payload;
    }
    elsif ($type eq 'EVENT') {
        if (my $e = $self->_process_event($source => $payload)) {
            push @{$self->{+BUFFERS}->{$source}} => $e;
            push @{$self->{+BUFFERS}->{$source}} => $e->event_id;
        }
        else {
            push @{$self->{+BUFFERS}->{$source}} => 'SYNC ERROR';
        }
    }
    else { # ENCODING
        $self->{+ENCODING}->{$source} = find_encoding($payload) // $self->audit_gen_harness_event(
            errors => [{
                fail    => 0,
                tag     => 'HARNESS',
                details => "Unable to find encoding '$payload', passing bytes through without decoding.",
            }],
        );
    }

    return $self->flush();
}

sub _process_event {
    my $self = shift;
    my ($source, $json) = @_;

    my $edata;
    my $ok  = eval { $edata = decode_json($json); 1; };
    my $err = $@;

    my $event;
    if ($ok) {
        $edata->{harness}->{from_stream} = $source;
        $edata->{harness}->{from_message} = 1;
        return $self->gen_event($edata);
    }

    $self->audit_gen_harness_event(
        harness => {parse_failure => 1},
        errors  => [{
            fail    => 1,
            tag     => 'HARNESS',
            details => "Error parsing event:\n======\n$json\n======\n$err",
        }],
    );

    return;
}

1;
