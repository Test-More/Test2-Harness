package Test2::Harness::Collector::Child;
use strict;
use warnings;

our $VERSION = '2.000000';

use Import::Into();
use Atomic::Pipe();
use constant();

use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;
use Test2::Util qw/get_tid/;
use Carp qw/confess croak/;

use Test2::Harness::Util::UUID qw/gen_uuid/;
use Test2::Harness::Util::JSON qw/encode_ascii_json/;

use vars qw/$STDERR_APIPE $STDOUT_APIPE/;

sub import {
    my $class = shift;

    confess "We do not appear to be inside a collector"
        unless $ENV{T2_HARNESS_PIPE_COUNT} || $STDERR_APIPE;

    my $caller = caller;

    for my $sub (@_) {
        croak "$class does not export $sub" unless $class->can($sub);

        my $val = $class->$sub();

        if (ref($val) eq 'CODE') {
            no strict 'refs';
            *{"$caller\::$sub"} = $val;
        }
        else {
            constant->import::into($caller, $sub, $val);
        }
    }
}

sub USE_PIPE_STDERR { return STDERR_APIPE() ? 1 : 0 }

sub STDOUT_APIPE {
    confess "We do not appear to be inside a collector"
        unless $ENV{T2_HARNESS_PIPE_COUNT} || $STDERR_APIPE;

    return $STDOUT_APIPE if $STDOUT_APIPE;
    return $STDOUT_APIPE = Atomic::Pipe->from_fh('>&=', \*STDOUT);
}

sub STDERR_APIPE {
    confess "We do not appear to be inside a collector"
        unless $ENV{T2_HARNESS_PIPE_COUNT} || $STDERR_APIPE;

    return $STDERR_APIPE if $STDERR_APIPE;
    return unless $ENV{T2_HARNESS_PIPE_COUNT} > 1;
    return $STDERR_APIPE = Atomic::Pipe->from_fh('>&=', \*STDERR);
}

sub send_event {
    confess "We do not appear to be inside a collector"
        unless $ENV{T2_HARNESS_PIPE_COUNT} || $STDERR_APIPE;

    my $stdout = STDOUT_APIPE();
    my $stderr = STDERR_APIPE();

    $stdout->set_mixed_data_mode();
    $stderr->set_mixed_data_mode() if $stderr;

    return sub {
        my ($in, %fields) = @_;
        my ($event, $facets);

        if (blessed($in) && $in->isa('Test2::Harnes::Event')) {
            $event = $in;
            $facets = $event->facet_data;
            $in->{$_} = $fields{$_} for keys %fields;
        }
        elsif ($in->{facet_data}) {
            $event = { %$in, %fields };
            $facets = $in->{facet_data};
        }
        else {
            $facets = $in;
            $event = \%fields;
        }

        my $event_id = $event->{event_id} //= $facets->{about}->{uuid} //= $fields{event_id} //= gen_uuid();
        $facets->{about}->{uuid} //= $event_id;

        $event->{facet_data} = $facets;
        $event->{event_id}   = $event_id;

        $event->{stamp} //= time;
        $event->{tid}   //= get_tid();
        $event->{pid}   //= $$;

        my $json;
        {
            no warnings 'once';
            local *UNIVERSAL::TO_JSON = sub { "$_[0]" };

            $json = encode_ascii_json($event);
        }

        $stdout->write_message($json);
        $stderr->write_message(qq/{"event_id":"$event_id"}/) if $stderr;
    };
}

1;
