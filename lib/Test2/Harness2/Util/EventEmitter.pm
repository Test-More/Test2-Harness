package Test2::Harness2::Util::EventEmitter;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Time::HiRes qw/time/;
use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Util::JSON qw/encode_json/;

use Object::HashBase qw{
    <pipe
    <stderr_pipe
    <job_id
    <run_id
};

sub init {
    my $self = shift;
    croak "'pipe' is required (an Atomic::Pipe in mixed_data_mode)"
        unless $self->{+PIPE};
}

sub emit_event {
    my ($self, %fields) = @_;

    my $event_id = gen_uuid();
    my $stamp    = time;

    my $event = {
        event_id   => $event_id,
        stamp      => $stamp,
        pid        => $$,
        facet_data => {
            harness => {
                event_id => $event_id,
                stamp    => $stamp,
                job_id   => $self->{+JOB_ID},
                run_id   => $self->{+RUN_ID},
                %fields,
            },
        },
    };

    return $self->emit_raw($event);
}

sub emit_raw {
    my ($self, $event) = @_;

    # Make sure the top-level event_id and the harness facet event_id agree.
    # If only one is set, propagate it; if neither, generate one; if both are
    # set to different values, refuse to emit -- that is always a caller bug.
    my $top     = $event->{event_id};
    my $harness = $event->{facet_data}{harness}{event_id};
    if (defined($top) && defined($harness) && $top ne $harness) {
        croak "event_id mismatch: top-level '$top' vs harness facet '$harness'";
    }
    my $event_id = $top // $harness // gen_uuid();
    $event->{event_id}                      = $event_id;
    $event->{facet_data}{harness}{event_id} = $event_id;

    my $json = encode_json($event);
    $self->{+PIPE}->write_message($json);

    if (my $se = $self->{+STDERR_PIPE}) {
        $se->write_message(qq/{"event_id":"$event_id"}/);
    }

    return $event_id;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::EventEmitter - Write structured events to an Atomic::Pipe without loading Test2::API

=head1 SYNOPSIS

    use Test2::Harness2::Util::EventEmitter;
    use Atomic::Pipe;

    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);

    my $emitter = Test2::Harness2::Util::EventEmitter->new(
        pipe   => $w,
        job_id => 'svc-job-1',
        run_id => 'some-run-uuid',
    );

    $emitter->emit_event(kind => 'lifecycle', note => 'starting up');

=head1 DESCRIPTION

A small standalone helper that writes structured events to an
L<Atomic::Pipe> in mixed-data mode using the same wire format that
L<Test2::Formatter::Stream2/_send_event> uses.  This allows services and
harness infrastructure code to emit lifecycle events that an existing
collector can read and process — without loading C<Test2::Formatter::Stream2>
or integrating with the L<Test2::API> hub.

Each call to L</emit_event> writes one atomic JSON message burst to the
pipe.  The collector on the other end reads it with
C<< $pipe->get_line_burst_or_data() >> and sees it as a C<message>-type
item, exactly the same as events produced by the Stream2 formatter.

=head1 ATTRIBUTES

=over 4

=item pipe (required)

An L<Atomic::Pipe> opened in C<mixed_data_mode>.  C<new()> croaks if this
is not provided.

=item stderr_pipe

An optional L<Atomic::Pipe> opened in C<mixed_data_mode> wrapping STDERR.
When set, L</emit_raw> writes a tiny C<{"event_id":"..."}> sync marker to
it after every event so the collector can interleave STDERR text with events
in emission order.  Defaults to C<undef>.

=item job_id

The job identifier baked into the C<harness> facet of every emitted event.
May be C<undef> for events that are not associated with a specific test job.

=item run_id

The run identifier baked into the C<harness> facet of every emitted event.
May be C<undef> for service-side events that precede a run.

=back

=head1 METHODS

=over 4

=item $event_id = $emitter->emit_event(%fields)

Build a harness-facet event, encode it as JSON, write it to L</pipe>, and
optionally write the STDERR sync marker to L</stderr_pipe>.  C<%fields> are
merged into the C<harness> facet alongside C<job_id> and C<run_id>.  Returns
the UUID assigned to the event.

=item $event_id = $emitter->emit_raw($event_hashref)

Write a pre-built event hashref as-is: encode to JSON, write the burst to
L</pipe>, and if L</stderr_pipe> is set write C<{"event_id":"..."}> to it.
Returns C<< $event->{event_id} >>.  Use this when the caller has already
assembled the full event shape (e.g. L<Test2::Formatter::Stream2>) and does
not need the harness-facet wrapping that L</emit_event> provides.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
