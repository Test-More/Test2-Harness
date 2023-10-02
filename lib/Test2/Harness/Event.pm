package Test2::Harness::Event;
use strict;
use warnings;

our $VERSION = '1.000155';

use Carp qw/confess/;
use Time::HiRes qw/time/;
use Test2::Harness::Util::JSON qw/encode_json/;

use Importer 'Test2::Util::Facets2Legacy' => ':ALL';

BEGIN {
    require Test2::Event;
    our @ISA = ('Test2::Event');

    # Currently the base class for events does not have init(), that may change
    if (Test2::Event->can('init')) {
        *INIT_EVENT = sub() { 1 }
    }
    else {
        *INIT_EVENT = sub() { 0 }
    }
}

use Test2::Harness::Util::HashBase qw{
    <facet_data
    <stream_id
    <event_id
    <run_id
    <job_id
    <job_try
    <stamp
    +json
    processed
};

sub trace     { $_[0]->{+FACET_DATA}->{trace} }
sub set_trace { confess "'trace' is a read only attribute" }

sub init {
    my $self = shift;

    $self->Test2::Event::init() if INIT_EVENT;

    my $data = $self->{+FACET_DATA} || confess "'facet_data' is a required attribute";

    for my $field (RUN_ID(), JOB_ID(), JOB_TRY(), EVENT_ID()) {
        my $v1 = $self->{$field};
        my $v2 = $data->{harness}->{$field};

        my $d1 = defined($v1);
        my $d2 = defined($v2);

        confess "'$field' is a required attribute"
            unless $d1 || $d2 || ($field eq +JOB_TRY && !$self->{+JOB_ID});

        confess "'$field' has different values between attribute and facet data"
            if $d1 && $d2 && $v1 ne $v2;

        $self->{$field} = $data->{harness}->{$field} = $v1 // $v2;
    }

    delete $data->{facet_data};

    # Original trace wins.
    if (my $trace = delete $self->{+TRACE}) {
        $self->{+FACET_DATA}->{trace} //= $trace;
    }
}

sub as_json { $_[0]->{+JSON} //= encode_json($_[0]) }

sub TO_JSON {
    my $out = {%{$_[0]}};

    $out->{+FACET_DATA} = { %{$out->{+FACET_DATA}} };
    delete $out->{+FACET_DATA}->{harness_job_watcher};
    delete $out->{+FACET_DATA}->{harness}->{closed_by};
    delete $out->{+JSON};
    delete $out->{+PROCESSED};

    return $out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Event - Subclass of Test2::Event used by Test2::Harness under
the hood.

=head1 DESCRIPTION

Test2 tests produce a sequence of events objects L<Test2::Event>. This is a
subclass of those events for use in L<Test2::Harness>. Event non-test tests
which produce TAP output will have the output parsed into these types of
events.

=head1 SYNOPSIS

In normal usage ou will never need to create one fo these events yourself. This
documentation assumes you are operating on an existing event C<$event> that the
harness exposed to you via a plugin or similar.

    my $facet_data = $event->facet_data;
    my $run_id     = $event->run_id;
    my $job_id     = $event->job_id;
    my $job_try    = $event->job_try;
    my $event_id   = $event->event_id;

=head1 METHODS

See L<Test2::Event> for methods provided by the base class.

=over 4

=item $hashref = $event->TO_JSON

Used for json serialization.

=item $json_string = $event->as_json

This will return a json representation of the event. Note that this is a lossy
conversion with some harness specific state removed by design. This may even be
a cached copy of the json string that was decoded to produce the original
object. If the string was not cached before it will be cached for all future
calls ignoring any state change to the event.

The lossy/cached conversion is intended so that events get passed through the
harness pipeline without modifications from one step translating to another. If
you need something extra to go through you need to either replace the event or
create an additional one.

=item $string = $event->event_id

Usually a UUID, but not always!

=item i$hashref = $event->facet_data

Get the event facet data, this is the meat of the event that hold all the
state.

=item $string = $event->job_id

Usually a UUID, but not always!

=item $int = $event->job_try

Integer, 0 or greater. Some jobs are run additional times if they fail, this
says which attempt the event is for. The counter starts at 0.

=item $bool = $event->processed

This will be true if the event has been process by the harness. Note that this
attibute is not serialized by C<TO_JSON> or C<as_json>.

=item $string = $event->run_id

The run id. This is usually a UUID, but not always!

=item $ts = $event->stamp

A unix timestamp for when the event was created.

=item $id = $event->stream_id

This is an implementation detail of L<Test2::Formatter::Stream>, do not rely on
it. This is used to prevent parsing errors when stream output is nested in
other stream output, which can happen if you are writing tests for the stream
formatter itself.

=item $trace = $event->trace

This si a shortcut for C<< $event->facet_data->{trace} >>. The trace data is
essential and used everywhere.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
