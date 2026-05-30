package Test2::Formatter::Stream2;
use v5.38;

our $VERSION = '2.000000';

use IO::Handle;

use Carp qw/croak confess/;
use Scalar::Util qw/blessed/;

use Test2::Harness2::Util qw/hub_truth apply_encoding/;
use Test2::Harness2::Util::EventEmitter;

use parent qw/Test2::Formatter/;
use Object::HashBase qw{
    +encoding
    <no_header
    <no_numbers
    <no_diag
    <tb
    <tb_handles
    <emitter
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Formatter::Stream2 - Test2 formatter that emits events directly to the
collector.

=head1 DESCRIPTION

Default L<Test2> formatter installed when tests run under
L<Test2::Harness2::Collector>. Instead of producing TAP, it serializes each
event as JSON and writes it as an atomic message burst on the test process's
STDOUT, with a small C<{"event_id":...}> sync marker on STDERR so the
collector can keep STDERR text ordered against the events.

This formatter cannot be used standalone -- it requires the environment set
up by the collector (specifically C<T2_HARNESS2_PIPE_COUNT>, which the child
inherits from the collector parent). Constructing it outside that
environment throws at C<init>-time.

The collector child also sets C<T2_FORMATTER=Stream2>, which is how
L<Test2::API> selects this formatter for the test process.

=head2 Test::Builder bridge

When constructed with C<< check_tb => 1 >>, the formatter instantiates a
L<Test::Builder::Formatter> alongside itself. If a caller later replaces
Test::Builder's stdout / stderr / todo handles (which legacy code
occasionally does to capture output) the formatter routes that one event
through Test::Builder's TAP path instead of the harness JSON path,
preserving legacy behavior. The C<handles>, C<set_handles>,
C<set_no_header>, C<set_no_diag>, C<set_no_numbers>, C<terminate>,
C<finalize>, and C<AUTOLOAD> hooks all forward to Test::Builder::Formatter
when the bridge is active.

=head1 ATTRIBUTES

=over 4

=item encoding

The active output encoding. Setting it via C<encoding> emits a control event
so the collector can mirror the change, and applies the encoding to both
STDOUT and STDERR.

=item no_header / no_diag / no_numbers

Mirror the Test::Builder formatter flags. Affect what is written for each
event (header / diagnostic info / assertion numbers respectively). When the
TB bridge is active, settings are propagated to it as well.

=item tb / tb_handles

Internal: the Test::Builder::Formatter bridge instance and its captured
initial handles. Populated only when C<check_tb> was passed to the
constructor.

=back

=cut

sub hide_buffered { 0 }

sub init ($self) {
    # T2_HARNESS2_PIPE_COUNT is set by Test2::Harness2::Collector in every
    # child process it spawns; its presence is our sole signal that we are
    # running inside a collector. The EventEmitter reads the same env var to
    # decide whether to wrap STDERR, so we just confirm the signal here and
    # let the emitter handle the actual pipe wrapping.
    confess "Test2::Formatter::Stream2 must be loaded inside a Test2::Harness2::Collector child (T2_HARNESS2_PIPE_COUNT is not set)"
        unless $ENV{T2_HARNESS2_PIPE_COUNT};

    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    if ($INC{'Test2/API.pm'}) {
        Test2::API::test2_stdout()->autoflush(1);
        Test2::API::test2_stderr()->autoflush(1);
    }

    $self->{+EMITTER} = Test2::Harness2::Util::EventEmitter->std;

    # Arm in-subtest STDOUT/STDERR-to-event conversion. On by default; a test
    # job opts out by setting T2_HARNESS2_IO_EVENTS to a false value (0/empty).
    # The emitter above already captured its pipe via a raw fd, so the tie this
    # installs (lazily, on the first subtest) cannot intercept it.
    unless (defined($ENV{T2_HARNESS2_IO_EVENTS}) && !$ENV{T2_HARNESS2_IO_EVENTS}) {
        require Test2::Formatter::Stream2::IOEvents;
        Test2::Formatter::Stream2::IOEvents->enable;
    }

    if ($self->{check_tb}) {
        require Test::Builder::Formatter;
        $self->{+TB}         = Test::Builder::Formatter->new();
        $self->{+TB_HANDLES} = [@{$self->{+TB}->handles}];
    }

    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item $self->write($event, $num, $facets)

Test2 formatter entry point. Routes the event through the Test::Builder
bridge when active and re-targeted (see L</Test::Builder bridge>), otherwise
hands it to L</record>.

=back

=cut

if ($^C) {
    no warnings 'redefine';
    *write = sub { };
}

sub write ($self, $e, $num = undef, $f = undef) {
    $f ||= $e->facet_data;

    $self->_set_encoding($f->{control}->{encoding}) if $f->{control}->{encoding};

    # Hide these if we must, but do not remove them for good.
    local $f->{info} if $self->{+NO_DIAG};
    local $f->{plan} if $self->{+NO_HEADER};

    # Test::Builder bridge: if Test::Builder's stdout/stderr/todo handles have
    # been swapped out since init (legacy tests do this to capture output),
    # route this one event through Test::Builder's TAP path instead of the
    # harness JSON path, so the capturing code still sees what it expects.
    # Buffered events are skipped because they arrive again as part of their
    # parent subtest event; writing them now would double-emit.
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
    return;
}

=over 4

=item record

=item $self->record($facets, $num)

Serialize one event's facet data and send it to the collector parent.

=back

=cut

sub record ($self, $facets, $num = undef) {
    # Local is expensive! Only do it if we really need to.
    local ($\, $,) = (undef, '') if $\ || $,;

    # Test2 passes the running assertion counter as $num. The canonical home
    # for the assertion number is facet_data.assert.number, which Test2
    # already populates upstream; we do not mirror it onto the event hash.
    $self->_send_event($facets);
    return;
}

=over 4

=item $enc = $self->encoding($enc)

Get or set the active encoding. Setting emits a control event and applies
the encoding to STDOUT / STDERR.

=back

=cut

sub encoding ($self, @args) {
    if (@args) {
        my ($enc) = @args;
        $self->record({control => {encoding => $enc}});
        $self->_set_encoding($enc);
        $self->{+TB}->encoding($enc) if $self->{+TB};
    }

    return $self->{+ENCODING};
}

=over 4

=item $self->handles

Forward to the Test::Builder bridge's handles when active; otherwise return
nothing (this formatter owns no TAP handles of its own).

=item $self->set_no_header($bool)

=item $self->set_no_diag($bool)

=item $self->set_no_numbers($bool)

Set the matching display flag, propagating to the Test::Builder bridge when
active.

=item $self->set_handles(...)

=item $self->terminate(...)

=item $self->finalize(...)

Standard Test2 formatter hooks. Forward to the Test::Builder bridge when
active, otherwise the no-op / superclass behavior.

=back

=cut

sub handles ($self) {
    return $self->{+TB}->handles if $self->{+TB};
    return;
}

sub set_no_header ($self, @args) {
    ($self->{+NO_HEADER}) = @args;
    $self->{+TB}->set_no_header(@args) if $self->{+TB};
    return $self->{+NO_HEADER};
}

sub set_no_diag ($self, @args) {
    ($self->{+NO_DIAG}) = @args;
    $self->{+TB}->set_no_diag(@args) if $self->{+TB};
    return $self->{+NO_DIAG};
}

sub set_no_numbers ($self, @args) {
    ($self->{+NO_NUMBERS}) = @args;
    $self->{+TB}->set_no_numbers(@args) if $self->{+TB};
    return $self->{+NO_NUMBERS};
}

sub set_handles ($self, @args) {
    return $self->{+TB}->set_handles(@args) if $self->{+TB};
    return;
}

sub terminate ($self, @args) {
    return $self->SUPER::terminate(@args) unless $self->{+TB};
    return $self->{+TB}->terminate(@args);
}

sub finalize ($self, @args) {
    return $self->SUPER::finalize(@args) unless $self->{+TB};
    return $self->{+TB}->finalize(@args);
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $self->_send_event($in, %fields)

Normalize C<$in> (a L<Test2::Harness2::Event>, an event hashref, or a bare
facet hashref) into an event and emit it through the configured emitter.

=item $enc = $self->_set_encoding($enc)

Apply C<$enc> to STDOUT / STDERR without emitting a control event.

=back

=cut

sub _send_event ($self, $in, %fields) {
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

    $event->{facet_data} = $self->_clean_facets($facets);

    {
        no warnings 'once';
        local *UNIVERSAL::TO_JSON = sub { "$_[0]" };
        $self->{+EMITTER}->emit_raw($event);
    }

    return;
}

=over 4

=item $clean = $self->_clean_facets($facets)

Return a cleaned copy of C<$facets> for the wire: empty facets, empty nested
hashes / arrays, and C<undef>-valued fields are dropped, and the redundant
C<trace.full_caller> array (a superset of C<trace.frame>) is removed. The
input is not mutated, so Test2's own facet structures are left intact. Events
reach the collector already clean; nothing downstream re-cleans them.

=item $copy = $self->_scrub($node)

Recursively copy C<$node>, dropping C<undef> hash values and any nested hash /
array that ends up empty. Non-reference and blessed values (JSON booleans,
etc.) are carried through untouched.

=back

=cut

sub _clean_facets ($self, $facets) {
    my $clean = $self->_scrub($facets);
    delete $clean->{trace}{full_caller} if ref $clean->{trace} eq 'HASH';
    return $clean;
}

sub _scrub ($self, $node) {
    if (ref $node eq 'HASH') {
        my %out;
        for my $key (keys %$node) {
            my $val = $node->{$key};
            next unless defined $val;

            if (ref $val eq 'HASH' || ref $val eq 'ARRAY') {
                my $sub = $self->_scrub($val);
                next if ref $sub eq 'HASH'  && !keys %$sub;
                next if ref $sub eq 'ARRAY' && !@$sub;
                $out{$key} = $sub;
            }
            else {
                $out{$key} = $val;
            }
        }
        return \%out;
    }

    return [map { ref $_ ? $self->_scrub($_) : $_ } @$node] if ref $node eq 'ARRAY';

    return $node;
}

sub _set_encoding ($self, @args) {
    if (@args) {
        my ($enc) = @args;

        apply_encoding(\*STDOUT, $enc);
        apply_encoding(\*STDERR, $enc);
    }

    return $self->{+ENCODING};
}

sub DESTROY { }

our $AUTOLOAD;

sub AUTOLOAD ($this, @args) {
    my $meth = $AUTOLOAD;
    $meth =~ s/^.*:://g;

    my $type = ref($this);

    return $this->{+TB}->$meth(@args)
        if $type && $this->{+TB} && $this->{+TB}->can($meth);

    $type ||= $this;
    croak qq{Can't locate object method "$meth" via package "$type"};
}

sub isa ($self, @args) {
    return $self->SUPER::isa(@args) unless ref($self) && $self->{+TB};
    return $self->SUPER::isa(@args) || $self->{+TB}->isa(@args);
}

sub can ($self, @args) {
    return $self->SUPER::can(@args) unless ref($self) && $self->{+TB};
    return $self->SUPER::can(@args) || $self->{+TB}->can(@args);
}

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
