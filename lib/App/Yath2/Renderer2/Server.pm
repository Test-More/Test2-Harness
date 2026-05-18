package App::Yath2::Renderer2::Server;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use parent 'App::Yath2::Renderer2::Base';

# Stub renderer reserving the `server` slot in the registry for the
# future yath UI / database renderer. The legacy implementation
# (App::Yath2::Renderer::Server, removed in Stage 9) hosted an
# ephemeral sqlite-backed database and a small web server that
# streamed events to a browser. A new pull-model equivalent will be
# rebuilt against the formatter-artifact store; this stub keeps the
# command and registry plumbing happy until that work lands.

# Empty option group so Registry's include_all_renderer_options does
# not blow up when this class is added there in the future. Currently
# the registry does not list `server`, so this group is dormant.
use Getopt::Yath;
option_group {group => 'server', prefix => 'server', category => 'Server renderer options'} => sub {
    option enabled => (
        type        => 'Bool',
        default     => 0,
        description => 'Reserved -- the server renderer is a stub in this release and has no effect.',
    );
};

sub start {
    my $self = shift;
    warn "App::Yath2::Renderer2::Server is a stub: no output will be produced. " . "Use --renderer terminal-auto or --renderer junit until the new server renderer ships.\n";
    return;
}

# Every hook is a no-op so the loop runs cleanly through any log
# without side effects. handle_*_opened / handle_*_sealed are
# inherited as no-ops from App::Yath2::Renderer2::Base; we explicitly
# do not override them here.

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer2::Server - Stub for the future server renderer.

=head1 DESCRIPTION

Placeholder renderer that reserves the C<server> short name in the
registry and prints a one-time warning at startup. Replaces the
legacy C<App::Yath2::Renderer::Server> module (removed in Stage 9
of the renderer refactor) until a pull-model equivalent is built
against the formatter-artifact store.

Producing no output is intentional: this renderer exists only to
keep the option plumbing and registry slot consistent while the
real implementation is designed.

=head1 SEE ALSO

L<App::Yath2::Renderer2::Base>,
L<App::Yath2::Renderer2::Terminal>,
L<App::Yath2::Renderer2::JUnit>.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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
