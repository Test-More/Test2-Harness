package App::Yath2::Renderer::Text::EventPainter;
use v5.38;

our $VERSION = '2.000000';

use List::Util qw/max/;
use Scalar::Util qw/blessed/;

use Object::HashBase qw{
    <theme
    <color
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
        verbosity => 1,    # 0 hides 2-only facets, 2 shows everything
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

# Facet render order: assert first, info last, the rest between.
my @FACET_ORDER = qw/assert control plan errors trace amnesty info/;

sub init ($self) {
    my %overrides;
    for my $key (keys %$self) {
        next if $key eq +THEME || $key eq +COLOR;
        $overrides{$key} = delete $self->{$key};
    }

    $self->{+COLOR} //= 0;
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
C<''>), C<verbosity> (default 1), C<max_width> (wrap threshold, default none),
and C<color> (override the instance default). A subtest event (one with
C<parent.children>) renders its own facets, then a C<\> branch marker, its
children at C<left_pad + 2>, then a C<^> terminator.

A stray event (C<harness_auditor.stray>) is a realtime copy of a
subtest-belonging event; it is painted flat with the C<:STRAY> node (C<E<gt>>),
dark grey, at no indentation regardless of C<left_pad>, and is never expanded.

=item $meta = $painter->parse_facet($facet_name, $facet_item)

Return a render-meta hash for one facet item, or C<undef> when the facet is not
renderable. The meta has: C<key> (theme lookup key -- a tag or facet name),
C<text>, C<verbosity> (0 never, 1 always, 2 verbose-only), C<multiline>,
C<max_width> (widest line), and the boolean flags C<assert>, C<fail>, C<diag>,
C<debug>, C<amnesty>.

=back

=cut

sub paint ($self, $in, %opts) {
    my $facets
        = blessed($in)                              ? $in->facet_data
        : (ref($in) eq 'HASH' && $in->{facet_data}) ? $in->{facet_data}
        :                                             $in;

    my $pad       = $opts{left_pad}  // 0;
    my $prefix    = $opts{prefix}    // '';
    my $verbosity = $opts{verbosity} // 1;
    my $max_width = $opts{max_width};
    my $color     = exists $opts{color} ? $opts{color} : $self->{+COLOR};

    # A stray event is a realtime copy of a subtest-belonging event: paint it
    # with the stray node ('>'), dark grey, and at no indentation regardless of
    # depth. It is flat -- never expand it as a subtest.
    my $stray = $facets->{harness_auditor} && $facets->{harness_auditor}{stray} ? 1 : 0;
    $pad = 0 if $stray;

    my @lines;
    for my $meta ($self->_ordered_metas($facets, $verbosity)) {
        push @lines => $self->_render_meta($meta, $pad, $prefix, $max_width, $color, $stray);
    }

    if (!$stray && $facets->{parent} && $facets->{parent}{children}) {
        push @lines => $self->_graph_marker('\\', $pad + 1, $prefix, $color);
        for my $child (@{$facets->{parent}{children}}) {
            push @lines => $self->paint($child, %opts, left_pad => $pad + 2);
        }
        push @lines => $self->_graph_marker('^', $pad + 2, $prefix, $color);
    }

    return @lines;
}

sub parse_facet ($self, $facet, $data) {
    my $meta = $self->_raw_meta($facet, $data) or return undef;

    my $text = $meta->{text} // '';
    $text =~ s/\n\z//;            # drop one trailing newline (e.g. a captured print)
    $meta->{text} = $text;

    my @lines = split /\n/, $text, -1;

    $meta->{multiline} = @lines > 1 ? 1 : 0;
    $meta->{max_width} = @lines ? max(map { length $_ } @lines) : 0;

    $meta->{$_} //= 0 for qw/assert fail diag debug amnesty/;
    $meta->{verbosity} //= 1;

    return $meta;
}

sub _raw_meta ($self, $facet, $data) {
    return $self->_meta_assert($data)  if $facet eq 'assert';
    return $self->_meta_info($data)    if $facet eq 'info';
    return $self->_meta_errors($data)  if $facet eq 'errors';
    return $self->_meta_plan($data)    if $facet eq 'plan';
    return $self->_meta_control($data) if $facet eq 'control';
    return $self->_meta_trace($data)   if $facet eq 'trace';
    return undef;
}

sub _meta_assert ($self, $data) {
    my $pass = $data->{pass} ? 1 : 0;
    return {
        key    => $pass ? 'PASS' : 'FAIL',
        assert => 1,
        fail   => $pass ? 0 : 1,
        text   => $data->{details} // '<UNNAMED ASSERTION>',
    };
}

sub _meta_info ($self, $data) {
    my $tag  = uc($data->{tag} // 'NOTE');
    my $diag = ($data->{debug} || $tag eq 'DIAG' || $tag eq 'STDERR') ? 1 : 0;

    return {
        key   => $tag,
        diag  => $diag,
        debug => $data->{debug} ? 1 : 0,
        text  => $self->_stringify($data->{details}),
    };
}

sub _meta_errors ($self, $data) {
    my $tag = uc($data->{tag} // ($data->{fail} ? 'FATAL' : 'ERROR'));
    return {
        key  => $tag,
        fail => $data->{fail} ? 1 : 0,
        diag => 1,
        text => $self->_stringify($data->{details}),
    };
}

sub _meta_plan ($self, $data) {
    return {key => 'NO  PLAN', verbosity => 2, text => $data->{details} // 'No plan'}
        if $data->{none};

    return {key => 'SKIP ALL', verbosity => 2, text => $data->{details} // 'No reason given'}
        if $data->{skip};

    return {key => 'PLAN', verbosity => 2, text => "Expected assertions: " . ($data->{count} // 0)};
}

sub _meta_control ($self, $data) {
    return {key => 'HALT', fail => 1, text => $data->{details} // 'halt'}
        if defined $data->{halt};

    return undef;
}

sub _meta_trace ($self, $data) {
    my $debug = $data->{details};
    if (!defined($debug) && $data->{frame}) {
        my $frame = $data->{frame};
        $debug = "$frame->[1] line $frame->[2]";
    }
    return undef unless defined $debug;

    return {key => 'DEBUG', debug => 1, diag => 1, text => $debug};
}

=head1 PRIVATE METHODS

=cut

=over 4

=item @metas = $self->_ordered_metas($facets, $verbosity)

The renderable facet metas for one event in display order (assert first, info
last), with verbosity filtering applied. A failing assertion's C<trace> becomes
a debug line; an C<amnesty> facet rewrites the assertion node to C<! PASS !>
and suppresses the debug line; C<amnesty> itself is never its own line.

=item @lines = $self->_render_meta($meta, $pad, $prefix, $max_width, $color)

Render one meta to one or more lines: a node-prefixed line per text line when
it fits, or a C<+>-delimited block of flush-left text when a line is too wide.

=item $line = $self->_graph_marker($char, $pad, $prefix, $color)

A structure-only line (branch C<\>, terminator C<^>, overflow C<+>) at the
given pad, colored with the graph color.

=item $node = $self->_theme_node($key) / $val = $self->_theme_attr($key, $attr)

Theme lookups, falling back to C<:DEFAULT>.

=item $str = $self->_stringify($details)

Render a facet's C<details> to a string -- a plain scalar as-is, a reference
through L<Data::Dumper>.

=item $theme = $self->_build_theme(\%overrides)

Merge user overrides over the built-in node/color defaults into a per-key theme.

=back

=cut

sub _ordered_metas ($self, $facets, $verbosity) {
    my $has_amnesty    = $facets->{amnesty} && @{$facets->{amnesty}} ? 1 : 0;
    my $assert         = $facets->{assert};
    my $failing_assert = $assert && !$assert->{pass} && !$has_amnesty ? 1 : 0;

    my @metas;
    for my $facet (@FACET_ORDER) {
        next unless exists $facets->{$facet};
        next if $facet eq 'amnesty';                          # modifies assert, no line
        next if $facet eq 'trace' && !$failing_assert;        # only debug a failure

        my $data  = $facets->{$facet};
        my @items = ref($data) eq 'ARRAY' ? @$data : ($data);

        for my $item (@items) {
            my $meta = $self->parse_facet($facet, $item) or next;

            if ($facet eq 'assert' && $has_amnesty) {
                $meta->{key}     = '! PASS !';
                $meta->{amnesty} = 1;
                $meta->{fail}    = 0;
            }

            next if $meta->{verbosity} == 0;
            next if $meta->{verbosity} == 2 && $verbosity < 2;

            push @metas => $meta;
        }
    }

    return @metas;
}

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

sub _stringify ($self, $details) {
    $details //= '';
    return $details unless ref $details;

    require Data::Dumper;
    my $dumper = Data::Dumper->new([$details])->Indent(2)->Terse(1)->Useqq(1)->Sortkeys(1);
    my $str = $dumper->Dump;
    chomp $str;
    return $str;
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
