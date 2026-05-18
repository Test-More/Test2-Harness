package App::Yath2::Options::Renderer;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use Test2::Harness2::Util qw/mod2file/;

use App::Yath2::Renderer::Registry();

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Term',
);

option_group {group => 'renderer', category => "Renderer Options"} => sub {
    option quiet => (
        type        => 'Bool',
        short       => 'q',
        description => "Be very quiet.",
        default     => 0,
    );

    option verbose => (
        type         => 'Count',
        short        => 'v',
        description  => "Be more verbose",
        initialize   => 0,
        set_env_vars => [qw/T2_HARNESS_IS_VERBOSE HARNESS_IS_VERBOSE/],
    );

    option qvf => (
        type        => 'Bool',
        default     => 0,
        description => "Quiet for passing tests, verbose for failing ones (QVF).",
    );

    option theme => (
        type        => 'Scalar',
        short       => 't',
        description => "Select a theme for the renderer (not all renderers use this).",
        default     => 'auto',
    );

    option wrap => (
        type        => 'Bool',
        default     => 1,
        description => "When active (default) renderers should try to wrap text in a human-friendly way.",
    );

    option show_times => (
        type        => 'Bool',
        short       => 'T',
        description => 'Show the timing data for each job.',
    );

    # Renderer set: short names resolvable via
    # App::Yath2::Renderer::Registry (e.g. terminal, terminal-auto,
    # junit), or "+Fully::Qualified::Class" for custom renderers.
    option classes => (
        type  => 'Map',
        name  => 'renderers',
        field => 'classes',
        alt   => ['renderer'],

        description => 'Select renderer(s) to run. Each --renderer NAME spawns one child process driving the named renderer. Use "+Fully::Qualified::Class" for custom renderers; short names (e.g. terminal, terminal-auto, junit) are resolved via the renderer registry. Default: terminal-auto.',

        long_examples  => [' terminal', ' junit', ' +My::Renderer'],
        short_examples => [' terminal', ' junit', ' +My::Renderer'],

        # Default set: terminal-auto (selects txt vs tty by tty-ness).
        initialize => sub { {'terminal-auto' => []} },

        # Keep the user-supplied name verbatim; Registry resolves at
        # spawn time. We do not normalize to a fully-qualified class
        # here because the user's short name is also the option-group
        # prefix used to surface that renderer's flat options.
        normalize => sub { ($_[0], ref($_[1]) ? $_[1] : [split(',', $_[1] // '')]) },
    );
};

# Build per-renderer spawn specs from the parsed Settings. Returns a
# list of hashrefs, one per active renderer:
#
#   { name => 'terminal', class => 'App::Yath2::Renderer::Terminal',
#     prefix => 'terminal', args => [...] }
#
# Each entry is what the parent command needs to fork a renderer
# child (whether in-process via App::Yath2::Renderer::Loop or via
# system($yath, 'render', NAME, ...)).
sub renderer_specs {
    my $class = shift;
    my ($settings) = @_;

    return [] unless $settings->check_group('renderer');

    my $rs        = $settings->renderer;
    my $r_classes = $rs->classes // {};
    return [] unless keys %$r_classes;

    my @specs;
    for my $name (sort keys %$r_classes) {
        my ($mod, $prefix) = App::Yath2::Renderer::Registry->resolve_and_load($name);
        push @specs, {
            name   => $name,
            class  => $mod,
            prefix => $prefix,
            args   => $r_classes->{$name} // [],
        };
    }

    return \@specs;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Renderer - Renderer selection and shared verbosity options.

=head1 DESCRIPTION

Defines the C<--renderer NAME> / C<--no-renderer> option pair plus the
shared verbosity / theme / wrap / timing flags that all renderers
consult. Parent commands (C<test>, C<run>, C<replay>, C<watch>) call
L</renderer_specs> to obtain one spawn descriptor per active renderer.

=head2 Default renderer set

C<terminal-auto> — selects the C<txt> or C<tty> formatter automatically
based on whether the output sink is a tty.

=head2 Selection semantics

=over 4

=item C<--renderer NAME>

Append C<NAME> to the active renderer set. C<NAME> is either a short
name registered in L<App::Yath2::Renderer::Registry> (C<terminal>,
C<terminal-auto>, C<junit>) or a fully-qualified Perl class prefixed
with C<+>.

=item C<--no-renderer>

Clear the active renderer set entirely. Combine with one or more
C<--renderer NAME> flags to start fresh and choose explicitly.

=back

=head2 Per-renderer options

Each renderer owns a flat option prefix (e.g. C<--terminal-out>,
C<--junit-out>). Those options are declared on the renderer class
itself; this option group only handles which renderers run and the
shared display knobs.

=head1 METHODS

=over 4

=item $specs = App::Yath2::Options::Renderer->renderer_specs($settings)

Resolve every active short renderer name via
L<App::Yath2::Renderer::Registry/resolve_and_load> and return one
spawn descriptor per renderer. Each descriptor is a hashref with the
keys C<name> (short name as typed), C<class> (resolved Perl class),
C<prefix> (flat option-group prefix owned by this renderer), and
C<args> (any per-renderer args from the C<--renderer NAME=...> form).

Returns the empty list when the C<renderer> settings group is absent
or carries no entries.

=back

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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
