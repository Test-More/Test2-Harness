package App::Yath2::Renderer::TerminalAuto;
use strict;
use warnings;

our $VERSION = '2.000013';

use App::Yath2::Formatter::Txt;
use App::Yath2::Formatter::Tty;

# Return the formatter appropriate for an output filehandle.
# - If $out_fh is a TTY (or undef => check STDOUT): Tty formatter w/ color_mode=auto.
# - Otherwise: Txt formatter (canonical, persistable).
# Caller can override the choice by passing an explicit formatter to
# the renderer; this is just the default-picker.
sub pick {
    my (%args) = @_;
    my $out_fh = $args{out_fh} // \*STDOUT;
    if (-t $out_fh) {
        return App::Yath2::Formatter::Tty->new(color_mode => 'auto');
    }
    return App::Yath2::Formatter::Txt->new;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer::TerminalAuto - Pick a terminal formatter based on whether the output is a TTY

=head1 SYNOPSIS

    use App::Yath2::Renderer::TerminalAuto;

    my $formatter = App::Yath2::Renderer::TerminalAuto::pick(out_fh => \*STDOUT);
    # Returns App::Yath2::Formatter::Tty when STDOUT is a TTY,
    # App::Yath2::Formatter::Txt otherwise.

    # Check STDOUT directly (no argument):
    my $formatter = App::Yath2::Renderer::TerminalAuto::pick();

=head1 DESCRIPTION

A small helper that selects the right formatter for a Terminal renderer when
the user has not explicitly requested one.

=over 4

=item TTY output

Returns an L<App::Yath2::Formatter::Tty> instance with C<color_mode =E<gt> 'auto'>,
which enables ANSI colour when the terminal supports it.

=item Non-TTY output (pipe, regular file, in-memory scalar handle)

Returns an L<App::Yath2::Formatter::Txt> instance.  Plain text is canonical and
persistable, suitable for log files and piped output.

=back

The caller (typically C<Command::test>, C<Command::run>, or C<Command::replay>)
may override the selection by supplying an explicit formatter when constructing
the Terminal renderer.

=head1 FUNCTIONS

=head2 pick(%args)

    my $formatter = App::Yath2::Renderer::TerminalAuto::pick(out_fh => $fh);

Accepts an optional C<out_fh> filehandle.  When omitted, C<\*STDOUT> is used.
Returns either a L<App::Yath2::Formatter::Tty> or L<App::Yath2::Formatter::Txt>
instance as described above.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright 2026 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
