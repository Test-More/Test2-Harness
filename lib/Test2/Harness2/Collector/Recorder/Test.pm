package Test2::Harness2::Collector::Recorder::Test;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;

use parent 'Test2::Harness2::Collector::Recorder';

use Object::HashBase qw{
    <transitions_file
    <state_file
    -transitions_writer
    -state_writer
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Recorder::Test - Test-aware recorder that splits
state transitions and the final verdict into their own files.

=head1 DESCRIPTION

A L<Test2::Harness2::Collector::Recorder> subclass for test jobs. The auditor
(L<Test2::Harness2::Collector::Auditor::Test>) injects state-transition events
and a final-state event into the stream; this recorder routes them out of the
main events file:

=over 4

=item *

An event carrying a C<harness_state_transition> facet is written to the
B<transitions file> (and the touchfile, if any, is touched so monitors wake
up promptly).

=item *

An event carrying a C<harness_final_state> facet is written to the B<state
file>.

=item *

Every other event is written to the events file by the base recorder.

=back

All three files are C<jsonl.zst>. On L</finalize> the extra files are closed
alongside the base events file, and the touchfile is touched.

=head1 SYNOPSIS

    use Test2::Harness2::Collector::Recorder::Test;

    my $rec = Test2::Harness2::Collector::Recorder::Test->new(
        events_file      => "$dir/events.jsonl.zst",
        transitions_file => "$dir/transitions.jsonl.zst",
        state_file       => "$dir/state.jsonl.zst",
        touchfile        => "$dir/touch",            # optional
    );

=head1 ATTRIBUTES

In addition to the base recorder's C<events_file> and C<touchfile>:

=over 4

=item transitions_file (required)

Path to the C<jsonl.zst> file state-transition events are written to.

=item state_file (required)

Path to the C<jsonl.zst> file the final-state event is written to.

=back

=cut

sub init ($self) {
    $self->SUPER::init();

    croak "transitions_file is a required attribute"
        unless defined $self->{+TRANSITIONS_FILE} && length $self->{+TRANSITIONS_FILE};

    croak "state_file is a required attribute"
        unless defined $self->{+STATE_FILE} && length $self->{+STATE_FILE};

    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item $rec->record_event($event)

Route C<$event> by facet: C<harness_state_transition> to the transitions file
(touching the touchfile), C<harness_final_state> to the state file, everything
else to the events file via the base recorder.

=item finalize

=item $rec->finalize

Close the transitions and state files, then chain to the base recorder's
finalize (which closes the events file and touches the touchfile). Safe to
call more than once.

=back

=cut

sub record_event ($self, $event) {
    my $f = $event->facet_data;

    if ($f->{harness_state_transition}) {
        $self->_transitions_writer->print($event->as_json, "\n");
        $self->_touch($self->touchfile);
        return;
    }

    if ($f->{harness_final_state}) {
        $self->_state_writer->print($event->as_json, "\n");
        return;
    }

    return $self->SUPER::record_event($event);
}

sub finalize ($self) {
    for my $slot (TRANSITIONS_WRITER, STATE_WRITER) {
        my $writer = delete $self->{$slot} or next;
        warn "recorder file close failed: $@\n" unless eval { $writer->close; 1 };
    }

    $self->SUPER::finalize();

    return;
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $writer = $self->_transitions_writer

=item $writer = $self->_state_writer

Lazily open (and cache) the zstd writer for the transitions / state file, so a
recorder that never sees a transition or final-state event does not create
the file.

=back

=cut

sub _transitions_writer ($self) {
    return $self->{+TRANSITIONS_WRITER} //= open_zstd_writer($self->{+TRANSITIONS_FILE});
}

sub _state_writer ($self) {
    return $self->{+STATE_WRITER} //= open_zstd_writer($self->{+STATE_FILE});
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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
