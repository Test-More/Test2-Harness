package App::Yath2::Options::Yath;
use strict;
use warnings;

our $VERSION = '2.000011';

use Getopt::Yath;

# Stage 4 scope: only the top-level options the App::Yath2 dispatcher
# needs to recognize before dispatching to a command. Additional
# options (plugins, scan_options, project, base_dir, user, help,
# show-opts, etc.) come back in Stage 6 when the rest of the old
# Yath.pm options module gets ported.

option_group {group => 'yath', category => 'Yath Options'} => sub {
    option version => (
        type        => 'Bool',
        short       => 'V',
        description => 'Show yath version information and exit.',
    );

    # Stage 6 — re-enable the autofill 'Auto' form so 'yath CMD
    # --help' routes through the command's include_options(). For
    # Stage 4 the top-level dispatcher matches 'yath --help' and
    # 'yath --help=GROUP' by hand before Getopt::Yath even runs,
    # so the option only needs to exist here to (a) not be
    # rejected if it slips through and (b) to feed the
    # 'yath --help=GROUP' group-scoped renderer its argument.
    option help => (
        type           => 'Auto',
        autofill       => 1,
        short          => 'h',
        description    => 'Show help and exit.',
        short_examples => ['', '=Group'],
        long_examples  => ['', '=Group'],
    );

    # Stage 6 — actual dev-lib handling (exec() re-launch, INC
    # manipulation, etc.) belongs to the real port from
    # old/lib/App/Yath2/Options/Yath.pm. Stage 4 just needs to
    # accept and swallow '-D' / '--dev-lib' so they don't bleed
    # through to the command parser.
    option dev_libs => (
        type           => 'AutoPathList',
        short          => 'D',
        name           => 'dev-lib',
        autofill       => sub { 'lib', 'blib/lib', 'blib/arch' },
        long_examples  => ['', '=lib', '="lib/*"'],
        short_examples => ['', 'lib',  '=lib', 'lib', '"lib/*"'],
        description    => 'Add developer library paths (stub in Stage 4; real exec-relaunch logic arrives in Stage 6).',
    );
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Yath - Top-level yath options.

=head1 DESCRIPTION

Defines the top-level C<yath> options parsed by L<App::Yath2> before
the command name is dispatched. This is the Stage 4 skeleton; the
full option set (plugins, project, base_dir, show-opts, etc.) is
restored in Stage 6.

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
