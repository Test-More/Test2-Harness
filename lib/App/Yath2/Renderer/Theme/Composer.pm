package App::Yath2::Renderer::Theme::Composer;
use strict;
use warnings;

our $VERSION = '2.000011';

use Scalar::Util qw/blessed/;
use List::Util qw/first/;

# Port of old/lib/App/Yath2/Renderer/Default/Composer.pm -- the logic
# that turns a facet-data structure into a list of
#   [ $facet_name, $tag, $text_for_humans ]
# triples suitable for a text renderer. Pure class methods; a blessed
# instance is offered only for ergonomics.
#
# This lives under Renderer::Theme:: because the same composition
# logic is shared by every text renderer in the tree (Default,
# Formatter, and any future QVF / TAPHarness port). Moving it out of
# Renderer::Default makes the dependency visible: Default is a
# consumer of the Composer, not its owner.

sub new {
    my $class = shift;
    return bless({}, $class);
}

sub render_one_line {
    my $class = shift;
    my $in    = shift;
    my $f     = blessed($in) ? $in->facet_data : $in;

    return [$f->{render}->[0]->{facet}, uc($f->{render}->[0]->{tag}), $f->{render}->[0]->{details}]
        if $f->{render} && @{$f->{render}};

    return (($class->render_control($f))[0])
        if $f->{control} && defined $f->{control}->{halt};

    for my $type (qw/assert errors plan info about/) {
        next unless $f->{$type};
        my $m = "render_$type";
        my ($out) = $class->$m($f);
        return $out if defined $out;
    }

    return;
}

sub render_verbose {
    my $class = shift;
    my ($in, %params) = @_;

    my $f = blessed($in) ? $in->facet_data : $in;

    return [map { [$_->{facet}, uc($_->{tag}), $_->{details}] } @{$f->{render}}]
        if $f->{render} && @{$f->{render}};

    my @out;

    push @out => $class->render_control($f, %params) if $f->{control};
    push @out => $class->render_plan($f)             if $f->{plan};

    if ($f->{assert}) {
        push @out => $class->render_assert($f);
        push @out => $class->render_debug($f)
            unless $f->{assert}->{pass} || $f->{assert}->{no_debug};
        push @out => $class->render_amnesty($f)
            if $f->{amnesty} && @{$f->{amnesty}};
    }

    push @out => $class->render_info($f)   if $f->{info};
    push @out => $class->render_errors($f) if $f->{errors};

    push @out => $class->render_about($f)
        if $f->{about}
        && !(@out || first { $f->{$_} } qw/stop plan info nest assert/);

    return \@out;
}

sub render_control {
    my $class = shift;
    my ($f, %params) = @_;

    my @out;

    push @out => ['control', 'HALT', $f->{control}->{details}]
        if defined $f->{control}->{halt};

    return @out unless $params{super_verbose};

    push @out => ['control', 'ENCODING', $f->{control}->{encoding}]
        if $f->{control}->{encoding};

    return @out if @out;

    return ['control', 'CONTROL', $f->{control}->{details}]
        if defined $f->{control}->{details};

    return;
}

my %SHOW_BRIEF_TAGS = (
    'CRITICAL' => 1,
    'DEBUG'    => 1,
    'DIAG'     => 1,
    'ERROR'    => 1,
    'FAIL'     => 1,
    'FAILED'   => 1,
    'FATAL'    => 1,
    'HALT'     => 1,
    'PASSED'   => 1,
    'REASON'   => 1,
    'STDERR'   => 1,
    'TIMEOUT'  => 1,
    'WARN'     => 1,
    'WARNING'  => 1,
    'KILL'     => 1,
    'SKIPPED'  => 1,
);

my %SHOW_BRIEF_FACETS = (
    control => 1,
    error   => 1,
    trace   => 1,
);

sub render_brief {
    my $class = shift;
    my $in    = shift;
    my $f     = blessed($in) ? $in->facet_data : $in;

    if ($f->{render} && @{$f->{render}}) {
        my @show =
            grep { $SHOW_BRIEF_TAGS{uc($_->{tag})} || $SHOW_BRIEF_FACETS{lc($_->{facet})} }
            @{$f->{render}};
        return [map { [$_->{facet}, uc($_->{tag}), $_->{details}] } @show];
    }

    my @out;

    push @out => $class->render_control($f) if $f->{control};

    if ($f->{assert} && !$f->{assert}->{pass} && !$f->{amnesty}) {
        push @out => $class->render_assert($f);
        push @out => $class->render_debug($f)
            unless $f->{assert}->{no_debug};
    }

    if ($f->{info}) {
        my $if = {%$f, info => [grep { $_->{debug} || $_->{important} || $_->{peek} } @{$f->{info}}]};
        push @out => $class->render_info($if) if @{$if->{info}};
    }

    push @out => $class->render_errors($f) if $f->{errors};

    return \@out;
}

sub render_plan {
    my $class = shift;
    my ($f) = @_;

    my $plan = $f->{plan};
    return ['plan', 'NO  PLAN', $f->{plan}->{details}] if $plan->{none};

    if ($plan->{skip}) {
        return ['plan', 'SKIP ALL', $f->{plan}->{details}]
            if $f->{plan}->{details};

        return ['plan', 'SKIP ALL', "No reason given"];
    }

    return ['plan', 'PLAN', "Expected assertions: $f->{plan}->{count}"];
}

sub render_assert {
    my $class = shift;
    my ($f) = @_;

    my $name = $f->{assert}->{details} || '<UNNAMED ASSERTION>';

    return ['assert', '! PASS !', $name]
        if $f->{amnesty} && @{$f->{amnesty}};

    return ['assert', 'PASS', $name]
        if $f->{assert}->{pass};

    return ['assert', 'FAIL', $name];
}

sub render_amnesty {
    my $class = shift;
    my ($f) = @_;

    my %seen;
    return map {
        $seen{join '' => map { $_ // '' } @{$_}{qw/tag details/}}++
            ? ()
            : ['amnesty', $_->{tag}, $_->{details}]
    } @{$f->{amnesty}};
}

sub render_debug {
    my $class = shift;
    my ($f) = @_;

    my $trace = $f->{trace};

    my $debug;
    if ($trace) {
        $debug = $trace->{details};
        if (!$debug && $trace->{frame}) {
            my $frame = $trace->{frame};
            $debug = "$frame->[1] line $frame->[2]";
        }
    }

    $debug ||= "[No trace info available]";

    chomp($debug);

    return ['trace', 'DEBUG', $debug];
}

sub render_info {
    my $class = shift;
    my ($f) = @_;

    return map {
        my $details = $_->{details} // '';
        ['info', $_->{tag}, $details, $_->{table} || ()]
    } @{$f->{info}};
}

sub render_about {
    my $class = shift;
    my ($f) = @_;

    return if $f->{about}->{no_display};
    return unless $f->{about} && $f->{about}->{details};

    my $type;
    if ($f->{about}->{package}) {
        $type = $f->{about}->{package};
        $type =~ s/^.*:://;
    }
    $type //= 'ABOUT';

    return ['about', $type, $f->{about}->{details}];
}

sub render_errors {
    my $class = shift;
    my ($f) = @_;

    return map {
        my $details = $_->{details};
        my $tag     = $_->{tag} || ($_->{fail} ? 'FATAL' : 'ERROR');
        ['error', $tag, $details]
    } @{$f->{errors}};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer::Theme::Composer - Compose output components from event facets.

=head1 DESCRIPTION

Ports the composition logic from
C<old/lib/App/Yath2/Renderer/Default/Composer.pm> into the new
C<App::Yath2::Renderer::Theme::> namespace so every in-tree text
renderer can share it.

A composer turns a facet_data hash (or a
L<Test2::Harness2::Event> whose C<facet_data> looks the same) into
a list of triples:

    [ $facet_name, $tag, $text_for_humans ]

Each renderer decides how to format and colour those triples; the
Composer is format-agnostic and emits bare data.

All methods are class methods; a blessed instance is offered only
for ergonomics.

=head1 METHODS

=over 4

=item $inst = $class->new

Ergonomic constructor -- the returned instance carries no state and
all of its methods are still resolved against the class.

=item $triple = $class->render_one_line($event_or_facets)

Return one C<[facet, tag, text]> triple for the event, preferring
an explicit C<render> facet, then C<control/halt>, then the first
meaningful facet from assert / errors / plan / info / about.

=item $triples = $class->render_verbose($event_or_facets, %params)

Return every triple the event carries. C<%params> currently only
accepts C<super_verbose =E<gt> 1> for use by
L</render_control>.

=item $triples = $class->render_brief($event_or_facets)

Return only the triples marked as "brief-worthy" -- control HALT,
failing asserts, debug/important/peek info, and errors. Useful for
a qvf or summary renderer.

=item @triples = $class->render_control($f, %params)

Render a control facet. With C<super_verbose =E<gt> 1> emits
encoding / control-details triples in addition to halt.

=item @triples = $class->render_plan($f)

Render a plan facet (PLAN / SKIP ALL / NO PLAN).

=item @triples = $class->render_assert($f)

Render an assert facet (PASS / FAIL / ! PASS ! for amnestied fails).

=item @triples = $class->render_amnesty($f)

Render amnesty entries, de-duplicated by tag+details.

=item @triples = $class->render_debug($f)

Render a trace triple for a failing assert.

=item @triples = $class->render_info($f)

Render info facets as a list of triples, one per info entry.

=item @triples = $class->render_about($f)

Render an about facet, deriving the tag from the facet's package
basename when available.

=item @triples = $class->render_errors($f)

Render error facets, one triple per error.

=back

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
