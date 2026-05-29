package Test2::Harness2::Collector::Recorder::Test;
use v5.38;

our $VERSION = '2.000000';

use parent 'Test2::Harness2::Collector::Recorder';

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Recorder::Test - Test-aware recorder that routes
transitions and the final state to the transition sockets.

=head1 DESCRIPTION

A L<Test2::Harness2::Collector::Recorder> subclass for test jobs. The auditor
(L<Test2::Harness2::Collector::Auditor>) injects state-transition events and a
final-state event into the stream; this recorder keeps them out of the events
file and sends them to the transition sockets instead:

=over 4

=item *

An event carrying a C<harness_state_transition> facet is sent only to the
sockets. The C<starting> one also carries the collector C<name>, events file,
and C<try>; the others carry only the collector C<uuid>.

=item *

An event carrying a C<harness_final_state> facet is sent only to the sockets,
carrying the verdict (and, like every message, the collector C<uuid>). The
identity fields are not repeated -- they rode the start message.

=item *

Every other event is written to the events file by the base recorder.

=back

There is no separate state or transitions file; the verdict reaches consumers
through the sockets (and, for an in-process run, the info hash
L<Test2::Harness2::Collector/collect> returns).

=head1 SYNOPSIS

    use Test2::Harness2::Collector::Recorder::Test;

    my $rec = Test2::Harness2::Collector::Recorder::Test->new(
        events_file        => "$dir/events.jsonl.zst",
        transition_sockets => ["$dir/transitions.sock"],   # optional, any number
    );

=head1 PUBLIC METHODS

=cut

=over 4

=item $rec->record_event($event)

Route C<$event> by facet: a C<harness_state_transition> goes only to the
transition sockets (the C<starting> one also carries the collector C<name>,
events file, and C<try> -- the only message that does); a
C<harness_final_state> goes only to the sockets; everything else goes to the
events file via the base recorder.

=back

=cut

sub record_event ($self, $event) {
    my $f = $event->facet_data;

    if (my $transition = $f->{harness_state_transition}) {
        my @extra = $transition->{state} eq 'starting' ? $self->_start_extra : ();
        $self->_notify_sockets($f, @extra);
        return;
    }

    if ($f->{harness_final_state}) {
        $self->_notify_sockets($f);
        return;
    }

    return $self->SUPER::record_event($event);
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
