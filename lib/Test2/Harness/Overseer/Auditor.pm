package Test2::Harness::Overseer::Auditor;
use strict;
use warnings;

our $VERSION = '1.000043';

use Carp qw/croak confess/;
use Scalar::Util qw/blessed/;
use List::Util qw/first max/;
use Time::HiRes qw/time/;
use File::Spec();

use Test2::Harness::Util qw/hub_truth/;
use Test2::Harness::Util::JSON qw/encode_pretty_json/;
use Test2::Harness::Util::UUID qw/gen_uuid/;

use Test2::Harness::Overseer::Auditor::TimeTracker;
use Test2::Harness::Overseer::Auditor::Subtest;

use parent 'Test2::Harness::Overseer::EventGen';
use Test2::Harness::Util::HashBase qw{
    <job

    <times
    <subtest
    <hub_buffers
    <tap_buffers

    <write
};

sub init {
    my $self = shift;

    $self->SUPER::init();

    croak "'job' is a required attribute"     unless $self->{+JOB};
    croak "'write' is a required attribute"   unless $self->{+WRITE};

    $self->{+SUBTEST} //= Test2::Harness::Overseer::Auditor::Subtest->new();
    $self->{+TIMES}   //= Test2::Harness::Overseer::Auditor::TimeTracker->new();
    $self->{+HUB_BUFFERS} //= {};
    $self->{+TAP_BUFFERS} //= [];
}

sub process {
    my $self = shift;
    my ($event) = @_;

    $self->{+WRITE}->($self->process_event($event));
}

sub process_event {
    my $self = shift;
    my ($event) = @_;

    my $f  = $event->facet_data;
    my $hf = hub_truth($f);

    $self->{+TIMES}->process($event, $f);

    my $nested = $hf->{nested} // 0;
    my $is_tap = $f->{harness}->{from_tap} ? 1 : 0;

    $self->pre_process_tap($event, $nested, $is_tap, $f, $hf) if $is_tap;
    return unless $event;

    # Validate subtest
    $self->validate_subtest($event, $f) if $f->{parent};

    if ($nested) {
        $f->{harness}->{buffered} = 1;
        if (my $hid = $hf->{hid}) {
            push @{$self->{+HUB_BUFFERS}->{$hid} //= []} => $event;
        }
        elsif ($is_tap) {
            push @{$self->{+TAP_BUFFERS}->[$nested - 1] //= []} => $event;
        }
    }
    else {
        $self->{+SUBTEST}->process($event, $f, $hf);
    }

    return $event;
}

sub close_tap_subtest {
    my $self = shift;
    my ($buffer, $event, $f, $hf) = @_;

    unless ($event) {
        if (@$buffer && $buffer->[0]->facet_data->{harness}->{subtest_start}) {
            $event = shift @$buffer;

            $f = $event->facet_data;

            push @{$f->{errors} //= []} => {
                tag => 'HARNESS',
                fail => 1,
                details => 'TAP parsing error, buffered subtest ended abruptly with no closing brace.',
            };
        }

        $event //= $self->gen_event(
            assert => {pass => 0, details => 'unterminated subtest'},
            errors => [{
                tag     => 'HARNESS',
                details => 'TAP parsing error, unterminated subtest.',
                fail    => 1,
            }],
        );
    }

    $f  //= $event->facet_data;
    $hf //= hub_truth($f);

    if ($event->{harness}->{subtest_close}) {
        if (@$buffer && $buffer->[0]->facet_data->{harness}->{subtest_start}) {
            my $ne = shift @$buffer;
            %$f  = %{$ne->facet_data};
            %$hf = %{hub_truth($f)};
        }
        else {
            push @{$f->{errors} //= []} => {
                tag     => 'HARNESS',
                details => 'TAP parsing error, found buffered subtest close, but open subtest is not buffered.',
                fail    => 1,
            };
        }
    }

    $f->{assert} //= {pass => 1, details => "unnamed subtest"};
    $f->{parent}->{children} = $buffer;
    $f->{parent}->{details}  = $f->{assert}->{details} //= "unnamed subtest";

    return $event;
}

sub close_tap_subtests {
    my $self = shift;
    my ($nested, $event, $f, $hf) = @_;

    # Un-Terminated subtests?
    while ($nested < $#{$self->{+TAP_BUFFERS}}) {
        my $buffer = pop @{$self->{+TAP_BUFFERS}} // [];
        my $event = $self->close_tap_subtest($buffer);
        $self->validate_subtest($event);
        push @{$self->{+TAP_BUFFERS}->[-1] //= []} => $event;
    }

    my $buffer = pop @{$self->{+TAP_BUFFERS}} // [];
    $self->close_tap_subtest($buffer, $event, $f, $hf);
}

sub pre_process_tap {
    my $self = shift;
    my ($event, $nested, $is_tap, $f, $hf) = @_;

    if ($f->{harness}->{subtest_start}) {
        push @{$self->{+TAP_BUFFERS}->[$nested] //= []} => $event;
        $_[0] = undef;    # Remove event
        return;
    }

    if ($f->{harness}->{subtest_end} && !$self->{+TAP_BUFFERS}->[$nested]) {
        # Not actually a subtest end
        my $line   = delete $f->{harness}->{from_tap};
        my $stream = $f->{harness}->{from_stream};

        %$f = (
            harness => $f->{harness},
            info    => [{
                tag     => uc($stream),
                details => $line,
            }],
        );

        $f->{info}->[0]->{debug} = 1 if $stream eq 'stderr';

        %$hf = %{hub_truth($f)};

        $_[1] = $hf->{nested} // 0;    # Reset nested
        $_[2] = 0;                     # Reset is_tap

        return;
    }

    $self->close_tap_subtests($nested, $event, $f, $hf) if $nested < @{$self->{+TAP_BUFFERS}};
}

sub matching_events {
    my $self = shift;
    my ($ea, $eb) = @_;

    return 1 if $ea->event_id eq $eb->event_id;
    return 0 unless $ea->facet_data->{about} && $eb->facet_data->{about};
    return 1 if $ea->facet_data->{about}->{eid} eq $eb->facet_data->{about}->{eid};
    return 0;
}

sub validate_subtest {
    my $self = shift;
    my ($event, $f) = @_;

    my $p        = $f->{parent};
    my $hid      = $p->{hid};
    my $children = $p->{children};
    my $buffer   = $hid ? delete $self->{+HUB_BUFFERS}->{$hid} : undef;

    my $buffer_copy = $buffer ? [@$buffer] : undef;

    my $st = Test2::Harness::Overseer::Auditor::Subtest->new();

    for my $ef (@{$p->{children}}) {
        my $e;
        if (blessed($ef)) {
            $e = $ef;
            $ef = $e->facet_data;
        }
        else {
            $ef->{harness}->{from_stream} = $f->{harness}->{from_stream};
            $e = $self->gen_event($ef);
        }

        delete $ef->{harness}->{buffered};
        delete $ef->{harness}->{level};

        if ($buffer) {
            my $be = shift @$buffer;

            unless ($self->matching_events($e, $be)) {
                # Prevent getting the message for all events
                $buffer = undef;

                # For late review. We only include this on failure, not worth
                # the bandwidth when it matches 'children'.
                $p->{streamed} = $buffer_copy;

                my $e_json  = encode_pretty_json($f);
                my $be_json = encode_pretty_json($be->facet_data);

                push @{$f->{errors} //= []} => {fail => 0, tag => 'HARNESS', details => <<"EOT" };
Mismatch between stored subtest child events and buffered/streamed subtest
events seen by the harness. This is not fatal, but could be a sign that a
testing tool is doing something bad. No further buffer checking will be done
for this subtest.

Buffered Event:
$be_json
---------------

Subtest Event:
$e_json
--------------
EOT
            }
        }

        $e->level; # Make sure the level is set in the facet data.
        $st->process($e);
    }

    if (my @errors = $st->subtest_fail_error_facet_list) {
        push @{$f->{parent}->{children}} => {
            harness => {
                from_stream => 'harness',
                stamp       => time,
                run_id      => $self->{+RUN_ID},
                job_id      => $self->{+JOB_ID},
                job_try     => $self->{+JOB_TRY},
                event_id    => gen_uuid(),
            },
            errors => \@errors,
        };
        if ($f->{assert}->{pass}) {
            $f->{assert}->{audit_delta} = {pass => $f->{assert}->{pass}};
            $f->{assert}->{pass}        = 0;
        }
    }
}

sub finish {
    my $self = shift;

    while (my $buffer = pop @{$self->{+TAP_BUFFERS}}) {
        my $event = $self->close_tap_subtest($buffer);
        $self->validate_subtest($event);

        if (@{$self->{+TAP_BUFFERS}}) {
            push @{$self->{+TAP_BUFFERS}->[-1] //= []} => $event;
        }
        else {
            $self->{+SUBTEST}->process($event);
        }
    }

    my $st = $self->{+SUBTEST};

    my $file = $self->{+JOB}->file;
    my $f = {};

    $f->{harness_job_end} = {
        file     => $file,
        rel_file => File::Spec->abs2rel($file),
        abs_file => File::Spec->rel2abs($file),
        fail     => $st->fail(),
        stamp    => time,
    };

    if (my $exit = $st->exit) {
        $f->{harness_job_end}->{retry} = $exit->{retry};
    }

    if (my $plan = $st->plan) {
        $f->{harness_job_end}->{skip} = $plan->{details} || "No reason given" unless $plan->{count};
    }

    if (my $halt = $st->halt) {
        $f->{harness_job_end}->{halt} = $halt;
    }

    if (my $times = $self->times) {
        $times->set_stop(time);
        if ($times->useful) {
            $f->{harness_job_end}->{times} = $times->data_dump;
            push @{$f->{harness_job_fields}} => $times->job_fields;
            push @{$f->{info}}               => {tag => 'TIME', details => $times->summary, table => $times->table};
        }
    }

    my @errors = $st->fail_error_facet_list;
    push @{$f->{errors}} => @errors if @errors;

    my $summary = $self->gen_harness_event($f);
    $self->write->($summary);

    return;
}

1;
