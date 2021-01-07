package Test2::Harness::Overseer::EventGen;
use strict;
use warnings;

use Carp qw/croak/;
use Time::HiRes qw/time/;

use Test2::Harness::Util::UUID qw/gen_uuid/;

use Test2::Harness::Event;

our $VERSION = '1.000043';

use Test2::Harness::Util::HashBase qw{
    <run_id
    <job_id
    <job_try
};

sub init {
    my $self = shift;

    croak "'run_id' is a required attribute"  unless $self->{+JOB_ID};
    croak "'job_id' is a required attribute"  unless $self->{+JOB_ID};
    croak "'job_try' is a required attribute" unless defined $self->{+JOB_TRY};
}

sub _parse_args {
    my $self = shift;

    return $_[0] if @_ == 1;
    return {@_};
}

sub gen_harness_event {
    my $self = shift;
    my $fd   = $self->_parse_args(@_);

    $fd->{harness}->{from_stream} //= 'harness';
    $fd->{harness}->{stamp}       //= time;
    $fd->{about}->{package}       //= ref($self);

    unless ($fd->{trace}) {
        my @caller = caller();
        $fd->{trace} = {
            buffered    => 0,
            nested      => 0,
            frame       => [@caller[0 .. 3]],
            pid         => $$,
            tid         => 0,
        };
    }

    return $self->gen_event($fd);
}

sub gen_event {
    my $self = shift;
    my $fd   = $self->_parse_args(@_);

    my $uuid = $fd->{about}->{uuid} //= gen_uuid();

    my $stamp = $fd->{harness}->{stamp};
    $stamp //= $fd->{stream}->{stamp} if $fd->{stream};
    $stamp //= time;

    $fd->{harness}->{event_id} //= $uuid;
    $fd->{harness}->{job_id}   //= $self->job_id;
    $fd->{harness}->{job_try}  //= $self->job_try;
    $fd->{harness}->{run_id}   //= $self->run_id;
    $fd->{harness}->{stamp}    //= $stamp;

    return Test2::Harness::Event->new(facet_data => $fd);
}

1;
