package Test2::Harness2::Role::Auditor;
use strict;
use warnings;

our $VERSION = '2.000011';

use Role::Tiny;

requires 'audit_event';
requires 'fail_count';
requires 'pass_count';

sub passing { !$_[0]->fail_count }
sub failing { $_[0]->fail_count }

# Default no-op implementations. Auditors that need the run/job/ipcm info must
# override these themselves -- the role can't assume every consumer is a
# blessed hash or wants to track these values.
sub set_process_info { }
sub set_ipcm_info    { }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Auditor - Role for objects that audit events as they are produced.

=head1 DESCRIPTION

Auditors sit between the parser and the loggers in the collector pipeline.
Each event produced by the parser is handed to the auditor, which may inspect
it, mutate its own state, and return zero or more events to be forwarded to
the loggers. Auditors also track whether the process under observation is
passing or failing.

=head1 SYNOPSIS

    package My::Auditor;
    use strict;
    use warnings;

    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Auditor';

    # ...

    sub audit_event {
        my ($self, $event) = @_;
        # inspect, update internal state, return 0+ events
        return ($event);
    }

    sub passing    { !$_[0]->{fail_count} }
    sub failing    {  $_[0]->{fail_count} }
    sub fail_count {  $_[0]->{fail_count} // 0 }
    sub pass_count {  $_[0]->{pass_count} // 0 }

    1;

=head1 REQUIRED METHODS

Consumers must implement the following methods.

=over 4

=item @events = $auditor->audit_event($event)

Given a single L<Test2::Harness2::Event>, return zero or more events for
downstream consumers. The auditor may mutate its own internal state in the
process. The returned list may contain the original event, a transformed
event, or additional synthesized events. Returning an empty list drops the
event from the pipeline.

=item $n = $auditor->fail_count()

Return the number of failures the auditor has counted so far.

=item $n = $auditor->pass_count()

Return the number of passing assertions the auditor has counted so far.

=back

=head1 PROVIDED METHODS

The role ships default implementations for these, driven by L</fail_count>.
Consumers may override them if they need richer state (for example to model
intermediate or ambiguous states).

=over 4

=item $bool = $auditor->passing()

Default: true when L</fail_count> is zero.

=item $bool = $auditor->failing()

Default: true when L</fail_count> is non-zero.

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
