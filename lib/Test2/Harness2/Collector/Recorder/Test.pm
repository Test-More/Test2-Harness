package Test2::Harness2::Collector::Recorder::Test;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;

use parent 'Test2::Harness2::Collector::Recorder';

use Object::HashBase qw{
    <state_file
    -state_writer
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Recorder::Test - Test-aware recorder that keeps a
final-state file and notifies pipes of transitions.

=head1 DESCRIPTION

A L<Test2::Harness2::Collector::Recorder> subclass for test jobs. The auditor
(L<Test2::Harness2::Collector::Auditor>) injects state-transition events and a
final-state event into the stream; this recorder handles them specially
instead of writing them to the main events file:

=over 4

=item *

An event carrying a C<harness_state_transition> facet is B<not> written to a
file at all -- it is sent only to the notification pipes, so live monitors
learn of each transition as it happens.

=item *

An event carrying a C<harness_final_state> facet is written to the B<state
file> and also sent to the pipes.

=item *

Every other event is written to the events file by the base recorder.

=back

The state file is C<jsonl.zst>. On L</finalize> it is closed alongside the
base events file, and the base recorder's finalization message is sent to the
pipes.

=head1 SYNOPSIS

    use Test2::Harness2::Collector::Recorder::Test;

    my $rec = Test2::Harness2::Collector::Recorder::Test->new(
        events_file => "$dir/events.jsonl.zst",
        state_file  => "$dir/state.jsonl.zst",
        pipes       => [$pipe],                  # optional, any number
    );

=head1 ATTRIBUTES

In addition to the base recorder's C<events_file> and C<pipes>:

=over 4

=item state_file (required)

Path to the C<jsonl.zst> file the final-state event is written to.

=back

=cut

sub init ($self) {
    $self->SUPER::init();

    croak "state_file is a required attribute"
        unless defined $self->{+STATE_FILE} && length $self->{+STATE_FILE};

    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item $rec->record_event($event)

Route C<$event> by facet: a C<harness_state_transition> goes only to the
notification pipes; a C<harness_final_state> goes to the state file and the
pipes; everything else goes to the events file via the base recorder.

=item finalize

=item $rec->finalize

Close the state file, then chain to the base recorder's finalize (which closes
the events file and sends the finalization message to the pipes). Safe to call
more than once.

=back

=cut

sub record_event ($self, $event) {
    my $f = $event->facet_data;

    if ($f->{harness_state_transition}) {
        $self->_notify_pipes($event->as_json);
        return;
    }

    if ($f->{harness_final_state}) {
        my $json = $event->as_json;
        $self->_state_writer->print($json, "\n");
        $self->_notify_pipes($json);
        return;
    }

    return $self->SUPER::record_event($event);
}

sub finalize ($self) {
    if (my $writer = delete $self->{+STATE_WRITER}) {
        warn "state file close failed: $@\n" unless eval { $writer->close; 1 };
    }

    $self->SUPER::finalize();

    return;
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $writer = $self->_state_writer

Lazily open (and cache) the zstd writer for the state file, so a recorder that
never sees a final-state event does not create the file.

=back

=cut

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
