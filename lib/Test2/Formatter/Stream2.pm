package Test2::Formatter::Stream2;
use strict;
use warnings;

our $VERSION = '2.000011';

use IO::Handle;

use Carp qw/croak confess/;
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;
use Test2::Util qw/get_tid/;

use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Util qw/hub_truth apply_encoding/;
use Test2::Harness2::Util::EventEmitter;

use parent qw/Test2::Formatter/;
use Object::HashBase qw{
    +encoding
    <no_header
    <no_numbers
    <no_diag
    <stream_id
    <tb
    <tb_handles
    <emitter
};

sub hide_buffered { 0 }

sub init {
    my $self = shift;

    # T2_HARNESS2_PIPE_COUNT is set by Test2::Harness2::Collector in every
    # child process it spawns; its presence is our sole signal that we are
    # running inside a collector. The EventEmitter reads the same env var
    # to decide whether to wrap STDERR, so we just confirm the signal
    # here and let the emitter handle the actual pipe wrapping.
    confess "Test2::Formatter::Stream2 must be loaded inside a Test2::Harness2::Collector child (T2_HARNESS2_PIPE_COUNT is not set)"
        unless $ENV{T2_HARNESS2_PIPE_COUNT};

    $self->{+STREAM_ID} = 1;

    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    if ($INC{'Test2/API.pm'}) {
        Test2::API::test2_stdout()->autoflush(1);
        Test2::API::test2_stderr()->autoflush(1);
    }

    $self->{+EMITTER} = Test2::Harness2::Util::EventEmitter->std;

    if ($self->{check_tb}) {
        require Test::Builder::Formatter;
        $self->{+TB}         = Test::Builder::Formatter->new();
        $self->{+TB_HANDLES} = [@{$self->{+TB}->handles}];
    }
}

sub record {
    my $self = shift;
    my ($facets, $num) = @_;

    # Local is expensive! Only do it if we really need to.
    local ($\, $,) = (undef, '') if $\ || $,;

    my $id = $self->{+STREAM_ID}++;
    $self->_send_event(
        $facets,
        stream_id    => $id,
        assert_count => $self->{+NO_NUMBERS} ? undef : $num,
    );
}

# Serialize an event and send it to the collector parent: full JSON payload as
# an atomic message burst on STDOUT, and a tiny {"event_id":...} sync marker
# on STDERR (when STDERR is its own pipe) so the collector can keep STDERR
# text ordered against the events.
sub _send_event {
    my $self = shift;
    my ($in, %fields) = @_;

    my ($event, $facets);
    if (blessed($in) && $in->isa('Test2::Harness2::Event')) {
        $event    = $in;
        $facets   = $event->facet_data;
        $in->{$_} = $fields{$_} for keys %fields;
    }
    elsif ($in->{facet_data}) {
        $event  = {%$in, %fields};
        $facets = $in->{facet_data};
    }
    else {
        $facets = $in;
        $event  = \%fields;
    }

    my $event_id = $event->{event_id} //= $facets->{about}->{uuid} //= $fields{event_id} //= gen_uuid();
    $facets->{about}->{uuid} //= $event_id;

    $event->{facet_data} = $facets;
    $event->{event_id}   = $event_id;

    $event->{stamp} //= time;
    $event->{tid}   //= get_tid();
    $event->{pid}   //= $$;

    {
        no warnings 'once';
        local *UNIVERSAL::TO_JSON = sub { "$_[0]" };
        $self->{+EMITTER}->emit_raw($event);
    }
}

sub encoding {
    my $self = shift;

    if (@_) {
        my ($enc) = @_;
        $self->record({control => {encoding => $enc}});
        $self->_set_encoding($enc);
        $self->{+TB}->encoding($enc) if $self->{+TB};
    }

    return $self->{+ENCODING};
}

sub _set_encoding {
    my $self = shift;

    if (@_) {
        my ($enc) = @_;

        apply_encoding(\*STDOUT, $enc);
        apply_encoding(\*STDERR, $enc);
    }

    return $self->{+ENCODING};
}

if ($^C) {
    no warnings 'redefine';
    *write = sub { };
}

sub write {
    my ($self, $e, $num, $f) = @_;
    $f ||= $e->facet_data;

    $self->_set_encoding($f->{control}->{encoding}) if $f->{control}->{encoding};

    # Hide these if we must, but do not remove them for good.
    local $f->{info} if $self->{+NO_DIAG};
    local $f->{plan} if $self->{+NO_HEADER};

    # Test::Builder bridge: if Test::Builder's stdout/stderr/todo handles have
    # been swapped out since init (legacy tests do this to capture output),
    # route this one event through Test::Builder's TAP path instead of the
    # harness JSON path, so the capturing code still sees what it expects.
    #
    # An event is "TB only" when:
    #   * the current TB stdout or stderr handle differs from the one we
    #     captured at init time (a clear sign the caller rerouted output), OR
    #   * the TB todo handle is no longer one of our initial stdout/stderr
    #     handles (the caller installed an independent todo handle, which
    #     again means they want TB to drive output).
    #
    # Buffered events are skipped here because they arrive again as part of
    # their parent subtest event; writing them now would double-emit.
    my $tb_only = 0;
    if ($self->{+TB}) {
        $tb_only ||= $self->{+TB_HANDLES}->[0] != $self->{+TB}->{handles}->[0];
        $tb_only ||= $self->{+TB_HANDLES}->[1] != $self->{+TB}->{handles}->[1];

        my $todo_match = $self->{+TB_HANDLES}->[0] == $self->{+TB}->{handles}->[2]
            || $self->{+TB_HANDLES}->[1] == $self->{+TB}->{handles}->[2];

        $tb_only ||= !$todo_match;

        if ($tb_only) {
            my $buffered = hub_truth($f)->{buffered};
            $self->{+TB}->write($e, $num, $f) if $self->{+TB} && !$buffered;
            return;
        }
    }

    $self->record($f, $num);
}

sub handles {
    my $self = shift;

    return $self->{+TB}->handles if $self->{+TB};
    return;
}

sub set_no_header {
    my $self = shift;
    ($self->{+NO_HEADER}) = @_;
    $self->{+TB}->set_no_header(@_) if $self->{+TB};
    $self->{+NO_HEADER};
}

sub set_no_diag {
    my $self = shift;
    ($self->{+NO_DIAG}) = @_;
    $self->{+TB}->set_no_diag(@_) if $self->{+TB};
    $self->{+NO_DIAG};
}

sub set_no_numbers {
    my $self = shift;
    ($self->{+NO_NUMBERS}) = @_;
    $self->{+TB}->set_no_numbers(@_) if $self->{+TB};
    $self->{+NO_NUMBERS};
}

sub set_handles {
    my $self = shift;
    return $self->{+TB}->set_handles(@_) if $self->{+TB};
    return;
}

sub terminate {
    my $self = shift;
    return $self->SUPER::terminate(@_) unless $self->{+TB};
    return $self->{+TB}->terminate(@_);
}

sub finalize {
    my $self = shift;
    return $self->SUPER::finalize(@_) unless $self->{+TB};
    return $self->{+TB}->finalize(@_);
}

sub DESTROY { }

our $AUTOLOAD;

sub AUTOLOAD {
    my $this = shift;

    my $meth = $AUTOLOAD;
    $meth =~ s/^.*:://g;

    my $type = ref($this);

    return $this->{+TB}->$meth(@_)
        if $type && $this->{+TB} && $this->{+TB}->can($meth);

    $type ||= $this;
    croak qq{Can't locate object method "$meth" via package "$type"};
}

sub isa {
    my $in = shift;
    return $in->SUPER::isa(@_) unless ref($in) && $in->{+TB};
    return $in->SUPER::isa(@_) || $in->{+TB}->isa(@_);
}

sub can {
    my $in = shift;
    return $in->SUPER::can(@_) unless ref($in) && $in->{+TB};
    return $in->SUPER::can(@_) || $in->{+TB}->can(@_);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Formatter::Stream2 - Test2 formatter that emits events directly to the
collector.

=head1 DESCRIPTION

Default L<Test2> formatter installed by L<App::Yath2> when it runs tests under
L<Test2::Harness2::Collector>. Instead of producing TAP, it serializes each
event as JSON and writes it as an atomic message burst on the test process's
STDOUT, with a small C<{"event_id":...}> sync marker on STDERR so the
collector can keep STDERR text ordered against the events.

This formatter cannot be used standalone -- it requires the environment set
up by the collector (specifically C<T2_HARNESS2_PIPE_COUNT>, which the child
inherits from the collector parent). Constructing it outside that environment
will throw at C<init>-time.

=head2 Test::Builder bridge

When constructed with C<check_tb =E<gt> 1>, the formatter instantiates a
L<Test::Builder::Formatter> alongside itself. If a caller later replaces
Test::Builder's stdout/stderr/todo handles (which legacy code occasionally
does to capture output) the formatter routes that one event through
Test::Builder's TAP path instead of the harness JSON path, preserving legacy
behavior. The L</handles>, L</set_handles>, L</set_no_header>,
L</set_no_diag>, L</set_no_numbers>, L</terminate>, L</finalize>, and
C<AUTOLOAD> hooks all forward to Test::Builder::Formatter when the bridge is
active.

=head1 ATTRIBUTES

=over 4

=item encoding

The active output encoding. Setting it via L</encoding> emits a control
event so the collector can mirror the change, and applies the encoding to
both STDOUT and STDERR via L<Test2::Harness2::Util/apply_encoding>.

=item no_header / no_diag / no_numbers

Mirror the Test::Builder formatter flags. Affect what is written for each
event (header / diagnostic info / assertion numbers respectively). When the
TB bridge is active, settings are propagated to it as well.

=item stream_id

Monotonically-increasing stream sequence number stamped onto every event so
the collector / loggers can preserve emission order across pipes.

=item tb / tb_handles

Internal: the Test::Builder::Formatter bridge instance and its captured
initial handles. Populated only when C<check_tb> was passed to the
constructor.

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
