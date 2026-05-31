package App::Yath2::Renderer::EventDisplay;
use v5.38;

our $VERSION = '2.000000';

use List::Util qw/max/;
use Scalar::Util qw/blessed/;

use Object::HashBase;

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer::EventDisplay - Inspect a Test2 event: deduce per-facet
render-metadata (tag, kind, text, verbosity) and display order.

=head1 DESCRIPTION

Format-agnostic logic for turning an event's facets into a list of semantic
C<meta> records: which facets are renderable, in what order, what each one's
tag/kind is, and the text for humans. Presentation layers (the text painter, an
HTML renderer, ...) consume these metas and decide nodes, colors, markup, etc.
-- this module makes no presentation decisions.

A C<meta> is a plain hashref:

=over 4

=item facet

The facet name that produced it (C<assert>, C<info>, ...).

=item key

A semantic lookup key for presentation: an uppercase tag (C<PASS>, C<FAIL>,
C<! PASS !>, C<DIAG>, C<DEBUG>, C<STDERR>, C<NOTE>, C<ERROR>, C<FATAL>, C<HALT>,
C<PLAN>, ...) or a facet name.

=item text

The text for humans (one trailing newline stripped; interior newlines kept).

=item verbosity

When to show: C<0> never, C<1> always, C<2> verbose-only.

=item multiline / max_width

Whether C<text> spans multiple lines, and the widest line's length.

=item assert / fail / diag / debug / amnesty

Booleans describing the kind of thing this is.

=back

=head1 SYNOPSIS

    my $facets = App::Yath2::Renderer::EventDisplay->new;

    for my $meta ($facets->facet_metas($event, verbosity => 1)) {
        # $meta->{key}, $meta->{text}, $meta->{fail}, ...
    }

    if ($facets->is_subtest($event)) {
        my @children = $facets->subtest_children($event);
    }

=cut

# Facet render order: assert first, info last, the rest between.
my @FACET_ORDER = qw/assert control plan errors trace amnesty info/;

=head1 PUBLIC METHODS

All methods accept an event as a L<Test2::Harness2::Event>, a raw
C<< {facet_data => \%facets} >> event hashref, or a bare facet_data hashref.

=cut

=over 4

=item $facets = $self->facet_data($event)

Normalize C<$event> to its facet_data hashref.

=item $bool = $self->is_stray($event)

True when the event is a stray realtime copy (C<harness_auditor.stray>).

=item $bool = $self->is_subtest($event)

True when the event carries assembled subtest children
(C<parent.children>).

=item @children = $self->subtest_children($event)

The event's C<parent.children> (raw facet-hashes), or an empty list.

=item facet_metas

=item @metas = $self->facet_metas($event, verbosity => 1)

The renderable facet metas for one event in display order (assert first, info
last), with verbosity filtering applied (C<verbosity> is the highest level to
include; default 1). A failing assertion's C<trace> becomes a debug meta; an
C<amnesty> facet rewrites the assertion's C<key> to C<! PASS !> (and clears its
C<fail>) and suppresses the debug meta; C<amnesty> is never its own meta.

=item $meta = $self->parse_facet($facet_name, $facet_item)

The meta for one facet item, or C<undef> when it is not renderable. Cross-facet
rules (amnesty, failing-trace) are applied by L</facet_metas>, not here.

=back

=cut

sub facet_data ($self, $in) {
    return $in->facet_data if blessed($in);
    return $in->{facet_data} if ref($in) eq 'HASH' && $in->{facet_data};
    return $in;
}

sub is_stray ($self, $in) {
    my $f = $self->facet_data($in);
    return $f->{harness_auditor} && $f->{harness_auditor}{stray} ? 1 : 0;
}

sub is_subtest ($self, $in) {
    my $f = $self->facet_data($in);
    return $f->{parent} && $f->{parent}{children} ? 1 : 0;
}

sub subtest_children ($self, $in) {
    my $f = $self->facet_data($in);
    return @{$f->{parent}{children} // []} if $f->{parent};
    return ();
}

sub facet_metas ($self, $in, %opts) {
    my $facets    = $self->facet_data($in);
    my $verbosity = $opts{verbosity} // 1;

    my $has_amnesty    = $facets->{amnesty} && @{$facets->{amnesty}} ? 1 : 0;
    my $assert         = $facets->{assert};
    my $failing_assert = $assert && !$assert->{pass} && !$has_amnesty ? 1 : 0;

    my @metas;
    for my $facet (@FACET_ORDER) {
        next unless exists $facets->{$facet};
        next if $facet eq 'amnesty';                          # modifies assert, no meta
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

sub parse_facet ($self, $facet, $data) {
    my $meta = $self->_raw_meta($facet, $data) or return undef;

    $meta->{facet} = $facet;

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

=head1 PRIVATE METHODS

=cut

=over 4

=item $meta = $self->_raw_meta($facet, $data)

Dispatch to the per-facet meta builder, or C<undef> when the facet is not
renderable.

=item $str = $self->_stringify($details)

Render a facet's C<details> to a string -- a plain scalar as-is, a reference
through L<Data::Dumper>.

=back

=cut

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

sub _stringify ($self, $details) {
    $details //= '';
    return $details unless ref $details;

    require Data::Dumper;
    my $dumper = Data::Dumper->new([$details])->Indent(2)->Terse(1)->Useqq(1)->Sortkeys(1);
    my $str = $dumper->Dump;
    chomp $str;
    return $str;
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
