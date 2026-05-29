package Test2::Harness2::Collector::Role::Recorder;
use v5.38;

our $VERSION = '2.000000';

use Role::Tiny;

requires 'record_event';
requires 'finalize';

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Role::Recorder - Role implemented by collector
event recorders.

=head1 DESCRIPTION

A recorder is the sink at the end of the collector pipeline. After parsing
and the optional processor stage, every resulting L<Test2::Harness2::Event>
is handed to the recorder one at a time. The recorder decides what, if
anything, to do with each event -- the base recorder writes them all to a
single C<jsonl.zst> file; subclasses may route some events elsewhere.

This role pins the two methods the collector calls against a recorder.

=head1 REQUIRED METHODS

=over 4

=item $recorder->record_event($event)

Take a single L<Test2::Harness2::Event> and persist it however the recorder
sees fit. The collector calls this for every event the pipeline produces,
including the synthetic process-exit event.

=item $recorder->finalize

Called once after the collector has finished and the final event has been
recorded. The recorder flushes and closes whatever it opened. Implementations
must tolerate being called more than once.

=back

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
