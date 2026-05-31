package App::Yath2::Renderer::Text::EventPainter;
use v5.38;

our $VERSION = '2.000000';

use App::Yath2::Renderer::EventDisplay;

use Object::HashBase qw{
    <theme
    <color
    <facets
};

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer::Text::EventPainter - Paint a Test2 event into human
readable lines with a subtest graph on the left.

=head1 DESCRIPTION

Turns one event's facets into text lines. Each renderable facet becomes a row
whose left edge is a single-character graph node indicating what it is (a
passing assertion, a failure, a diagnostic, a note, ...). Subtests (events that
carry C<parent.children>) are drawn as an indented branch: the subtest's own
assertion, a C<\> branch marker, its children indented two columns, and a C<^>
terminator.

The output format is new; the node characters and colors echo the legacy
L<Test2::Formatter::Test2> renderer. Color is optional and uses
L<Term::ANSIColor> names.

=head1 SYNOPSIS

    my $painter = App::Yath2::Renderer::Text::EventPainter->new(color => 1);

    my @lines = $painter->paint(
        $event,            # a Test2::Harness2::Event or raw facet_data hashref
        verbosity => 1,    # max facet level to show: 1 = normal, 2 = also verbose-only facets (plans, etc.)
        left_pad  => 0,
        prefix    => '',
        max_width => 120,
    );

=head1 ATTRIBUTES

=over 4

=item theme

The merged theme: per-key C<{node, node_width, node_color, text_color}>. Keyed
by tag (C<PASS>, C<DIAG>, ...) or facet name, with C<:DEFAULT> as the fallback.
Constructor arguments other than C<color> are merged over the built-in default.

=item color

Whether to emit ANSI color. Defaults off.

=back

=cut

# Graph node characters for each tag/facet. ':DEFAULT' is the fallback.
my %DEFAULT_NODE = (
    ':DEFAULT'  => '|',
    ':STRAY'    => '>',
    PASS        => '*',
    FAIL        => 'X',
    '! PASS !'  => 'o',
    DIAG        => '!',
    DEBUG       => '!',
    STDERR      => '!',
    ERROR       => '!',
    REASON      => '!',
    TIMEOUT     => '!',
    FATAL       => 'X',
    HALT        => 'X',
    NOTE        => '|',
    STDOUT      => '|',
    PLAN        => '|',
    'NO  PLAN'  => '|',
    'SKIP ALL'  => '|',
);

# Term::ANSIColor names, echoing the legacy renderer's tag palette.
my %DEFAULT_COLOR = (
    ':STRAY'    => 'bright_black',
    PASS        => 'green',
    FAIL        => 'red',
    '! PASS !'  => 'cyan',
    DIAG        => 'yellow',
    DEBUG       => 'red',
    STDERR      => 'yellow',
    ERROR       => 'yellow',
    FATAL       => 'bold red',
    HALT        => 'bold red',
    REASON      => 'magenta',
    TIMEOUT     => 'magenta',
    'NO  PLAN'  => 'yellow',
    'SKIP ALL'  => 'bold cyan',
    PLAN        => 'blue',
);

# Color for the graph structure itself (branch/terminator/overflow markers).
use constant GRAPH_COLOR => 'bold bright_white';

sub init ($self) {
    my %overrides;
    for my $key (keys %$self) {
        next if $key eq +THEME || $key eq +COLOR || $key eq +FACETS;
        $overrides{$key} = delete $self->{$key};
    }

    $self->{+COLOR}  //= 0;
    $self->{+FACETS} //= App::Yath2::Renderer::EventDisplay->new;
    $self->{+THEME} = $self->_build_theme(\%overrides);

    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item @lines = $painter->paint($event, %opts)

Paint one event into text lines. C<$event> may be a
L<Test2::Harness2::Event> or a raw facet_data hashref. Options: C<left_pad>
(indent columns, default 0), C<prefix> (string before every line, default
C<''>), C<verbosity> (the highest facet level to show -- C<1> (default) shows
normal facets, C<2> also shows verbose-only facets such as plans; see
L<App::Yath2::Renderer::EventDisplay/facet_metas>), C<max_width> (wrap threshold,
default none), and C<color> (override the instance default). A subtest event (one with
C<parent.children>) renders its own facets, then a C<\> branch marker, its
children at C<left_pad + 2>, then a C<^> terminator.

A stray event (C<harness_auditor.stray>) is a realtime copy of a
subtest-belonging event; it is painted flat with the C<:STRAY> node (C<E<gt>>),
dark grey, at C<left_pad> but without any subtest indentation, and is never
expanded.

The facet-to-meta deduction and display ordering come from
L<App::Yath2::Renderer::EventDisplay>; this class only maps each meta's C<key> to a
node and colors. Each meta's C<verbosity> (C<0> never, C<1> always, C<2>
verbose-only) is filtered against the C<verbosity> option there.

=back

=cut

sub paint ($self, $in, %opts) {
    my $facets = $self->{+FACETS};

    my $pad       = $opts{left_pad}  // 0;
    my $prefix    = $opts{prefix}    // '';
    my $verbosity = $opts{verbosity} // 1;
    my $max_width = $opts{max_width};
    my $color     = exists $opts{color} ? $opts{color} : $self->{+COLOR};

    # A stray event is a realtime copy of a subtest-belonging event: paint it
    # with the stray node ('>'), dark grey, at the caller's left_pad but with no
    # subtest indentation -- it is flat, so it is never expanded as a subtest
    # and (being a top-level entry) never gains nesting depth.
    my $stray = $facets->is_stray($in);

    my @lines;
    for my $meta ($facets->facet_metas($in, verbosity => $verbosity)) {
        push @lines => $self->_render_meta($meta, $pad, $prefix, $max_width, $color, $stray);
    }

    if (!$stray && $facets->is_subtest($in)) {
        push @lines => $self->_graph_marker('\\', $pad + 1, $prefix, $color);
        for my $child ($facets->subtest_children($in)) {
            push @lines => $self->paint($child, %opts, left_pad => $pad + 2);
        }
        push @lines => $self->_graph_marker('^', $pad + 2, $prefix, $color);
    }

    return @lines;
}

=head1 PRIVATE METHODS

=cut

=over 4

=item @lines = $self->_render_meta($meta, $pad, $prefix, $max_width, $color)

Render one meta to one or more lines: a node-prefixed line per text line when
it fits, or a C<+>-delimited block of flush-left text when a line is too wide.

=item $line = $self->_graph_marker($char, $pad, $prefix, $color)

A structure-only line (branch C<\>, terminator C<^>, overflow C<+>) at the
given pad, colored with the graph color.

=item $node = $self->_theme_node($key) / $val = $self->_theme_attr($key, $attr)

Theme lookups, falling back to C<:DEFAULT>.

=item $theme = $self->_build_theme(\%overrides)

Merge user overrides over the built-in node/color defaults into a per-key theme.

=back

=cut

sub _render_meta ($self, $meta, $pad, $prefix, $max_width, $color, $stray = 0) {
    my $key    = $stray ? ':STRAY' : $meta->{key};
    my $node   = $self->_theme_node($key);
    my $indent = ' ' x $pad;

    my @text_lines = split /\n/, ($meta->{text} // ''), -1;
    @text_lines = ('') unless @text_lines;

    my $base_width = length($prefix) + $pad + length($node) + 2;

    if (defined $max_width) {
        for my $line (@text_lines) {
            next unless $base_width + length($line) > $max_width;

            # Too wide: dump the text flush-left between '+' markers.
            return (
                $self->_graph_marker('+', $pad, $prefix, $color),
                (map { $self->_paint_text($_, $key, $color) } @text_lines),
                $self->_graph_marker('+', $pad, $prefix, $color),
            );
        }
    }

    my $start = $prefix . $indent . $self->_paint_node($node, $key, $color) . '  ';
    return map { $start . $self->_paint_text($_, $key, $color) } @text_lines;
}

sub _graph_marker ($self, $char, $pad, $prefix, $color) {
    my $indent = ' ' x $pad;
    my $mark   = $color ? $self->_ansi($char, GRAPH_COLOR) : $char;
    return $prefix . $indent . $mark;
}

sub _theme_node ($self, $key) {
    my $t = $self->{+THEME};
    return $t->{$key}{node} // $t->{':DEFAULT'}{node} // '|';
}

sub _theme_attr ($self, $key, $attr) {
    my $t = $self->{+THEME};
    my $v = $t->{$key} ? $t->{$key}{$attr} : undef;
    $v //= $t->{':DEFAULT'}{$attr} if $t->{':DEFAULT'};
    return $v;
}

sub _paint_node ($self, $node, $key, $color) {
    return $node unless $color;
    return $self->_ansi($node, $self->_theme_attr($key, 'node_color'));
}

sub _paint_text ($self, $text, $key, $color) {
    return $text unless $color;
    return $self->_ansi($text, $self->_theme_attr($key, 'text_color'));
}

sub _ansi ($self, $text, $colorname) {
    return $text unless $colorname;
    require Term::ANSIColor;
    return Term::ANSIColor::color($colorname) . $text . Term::ANSIColor::color('reset');
}

sub _build_theme ($self, $overrides) {
    my %theme;

    my %keys = map { $_ => 1 } (keys %DEFAULT_NODE, keys %DEFAULT_COLOR, keys %$overrides);
    for my $key (keys %keys) {
        $theme{$key} = {
            node       => $DEFAULT_NODE{$key},
            node_width => undef,
            node_color => $DEFAULT_COLOR{$key},
            text_color => $DEFAULT_COLOR{$key},
        };
    }

    $theme{':DEFAULT'} //= {node => '|'};
    $theme{':DEFAULT'}{node} //= '|';

    for my $key (keys %$overrides) {
        my $o = $overrides->{$key};
        $theme{$key}{$_} = $o->{$_} for keys %$o;
    }

    return \%theme;
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
