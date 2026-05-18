package App::Yath2::Concluder::ResetTerm;
use strict;
use warnings;

our $VERSION = '2.000013';

use parent 'App::Yath2::Concluder';

# Emit a terminal reset to clear leftover SGR / scrolling / cursor state
# the renderer may have left behind. Only acts when out_fh is a TTY so
# the sequence is never embedded in piped or file-redirected output.
#
# The dispatch loop guarantees ResetTerm runs after every other
# concluder so it always has the last word on the terminal state.
sub run {
    my $self = shift;
    my $fh   = $self->out_fh;
    return unless -t $fh;

    # Matches the legacy renderer's reset: SGR clear + DEC private mode
    # 'reverse video off' (=l). Avoids the full "\ec" hard reset, which
    # also wipes scrollback on some terminals.
    print {$fh} "\e[0m\e[=l";
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Concluder::ResetTerm - End-of-run terminal reset.

=head1 DESCRIPTION

Writes a terminal reset sequence to C<out_fh> when it is a TTY. This
clears any leftover ANSI SGR state (colours, bold, underline, reverse,
etc.) the renderer may have left behind so the user's shell prompt
resumes in a clean state.

When C<out_fh> is not a TTY this concluder is a no-op: writing escape
sequences into piped or file-redirected output would corrupt log
captures.

The parent-process dispatcher always runs C<ResetTerm> last so it has
the final word on the terminal state, after any other concluder
(Summary, Notify, etc.) has finished writing.

=head1 METHODS

=over 4

=item $c->run

Write the terminal reset sequence to C<out_fh> when it is a TTY;
otherwise return without writing.

=back

=head1 SEE ALSO

L<App::Yath2::Concluder>.

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
