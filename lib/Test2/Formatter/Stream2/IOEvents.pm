package Test2::Formatter::Stream2::IOEvents;
use v5.38;

our $VERSION = '2.000000';

use Test2::API qw/test2_add_callback_pre_subtest/;

use Test2::Formatter::Stream2::IOEvents::Tie;

my $ENABLED = 0;

=pod

=encoding UTF-8

=head1 NAME

Test2::Formatter::Stream2::IOEvents - Turn prints to STDOUT/STDERR inside a
subtest into Test2 events.

=head1 DESCRIPTION

An optional companion to L<Test2::Formatter::Stream2>. When enabled, prints (and
warnings) to C<STDOUT> / C<STDERR> made while a subtest is running become Test2
C<info> events, so they fold into that subtest at the correct nesting instead of
landing loose in the log after it.

The conversion is done with a tie (L<Test2::Formatter::Stream2::IOEvents::Tie>),
installed lazily the first time a subtest starts -- nothing touches the I/O
layer until then. Outside a subtest the tie passes prints straight through to
the real handle, so top-level output, forks, and C<exec>'d commands are
unaffected.

This is B<on by default>. L<Test2::Formatter::Stream2> calls L</enable> at
C<init> unless C<T2_HARNESS2_IO_EVENTS> is set to a false value (C<0> or empty)
in the test child.

=head1 SYNOPSIS

    Test2::Formatter::Stream2::IOEvents->enable;

=head1 PUBLIC METHODS

=cut

=over 4

=item enable

=item Test2::Formatter::Stream2::IOEvents->enable

Arm the feature: register a C<pre_subtest> callback that installs the ties on
the first subtest entry. Idempotent -- only the first call registers anything.

=back

=cut

sub enable ($class) {
    return if $ENABLED;
    $ENABLED = 1;

    test2_add_callback_pre_subtest(sub { $class->_install_ties });

    return;
}

=head1 PRIVATE METHODS

=cut

=over 4

=item Test2::Formatter::Stream2::IOEvents->_install_ties

Tie C<STDOUT> and C<STDERR> to L<Test2::Formatter::Stream2::IOEvents::Tie>.
Idempotent: a handle already tied is left as-is. Run on every subtest start (by
the L</enable> callback), so a tie dropped by an intervening reopen -- e.g.
L<Capture::Tiny> or an explicit C<< open STDOUT, ... >> -- is refreshed before
the next subtest.

=item Test2::Formatter::Stream2::IOEvents->_uninstall_ties

Untie C<STDOUT> and C<STDERR> if they are tied. Used for cleanup / tests.

=back

=cut

sub _install_ties ($class) {
    # Called at every subtest start, so an untied handle (one whose tie an
    # intervening reopen dropped) is re-tied here. A handle still tied -- to us
    # or to another module -- is left alone so we never clobber a live tie.
    tie(*STDOUT, 'Test2::Formatter::Stream2::IOEvents::Tie', 'STDOUT') unless tied(*STDOUT);
    tie(*STDERR, 'Test2::Formatter::Stream2::IOEvents::Tie', 'STDERR') unless tied(*STDERR);
    return;
}

sub _uninstall_ties ($class) {
    untie(*STDOUT) if tied(*STDOUT);
    untie(*STDERR) if tied(*STDERR);
    return;
}

1;

__END__

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
