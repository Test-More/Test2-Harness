package Test2::Harness2::Collector::Role::Auditor;
use v5.38;

our $VERSION = '2.000000';

use Role::Tiny;

requires 'pass';
requires 'fail';

sub passing ($self) { $self->pass }
sub failing ($self) { $self->fail }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Role::Auditor - Role implemented by collector
auditors.

=head1 DESCRIPTION

An auditor decides the pass/fail verdict of a single test execution. It
consumes the parsed events for one test, tracks assertions, plans, subtests,
errors, and the process exit code, and exposes a final C<pass>/C<fail>
verdict.

=head1 SYNOPSIS

    package My::Auditor;
    use v5.38;

    use Role::Tiny::With;
    with 'Test2::Harness2::Collector::Role::Auditor';

    sub pass ($self) { ... }
    sub fail ($self) { ... }

=head1 REQUIRED METHODS

=over 4

=item $bool = $auditor->pass

True when the test execution passed.

=item $bool = $auditor->fail

True when the test execution failed.

=back

=head1 PUBLIC METHODS

=over 4

=item $bool = $auditor->passing

Alias for C<pass>.

=item $bool = $auditor->failing

Alias for C<fail>.

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
