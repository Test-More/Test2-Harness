package App::Yath2::Formatter::Txt;
use strict;
use warnings;

our $VERSION = '2.000013';

use Scalar::Util qw/blessed/;

use parent 'App::Yath2::Formatter';

sub produces_artifact { 1 }

# Convert a single event item to plain text. Facets are rendered in a
# canonical order that matches the verbose path of the legacy Default
# renderer, but without any color, ANSI escape codes, or terminal-width
# wrapping. Display policy (color, width, verbosity level) is the
# responsibility of the renderer layer; this formatter outputs only the
# canonical content.
#
# Facet rendering order:
#   control        — HALT lines and encoding notices
#   plan           — test plan (count / skip-all / no-plan)
#   assert         — pass/fail assertion with optional amnesty/debug
#   parent         — subtest children (recursive, indented 2 spaces)
#   info           — note/diag lines
#   errors         — error lines
#   about          — fallback event label
#   harness_job_*  — job lifecycle markers
sub convert_item {
    my ($self, $item) = @_;
    my $fd = $item->{facet_data} or return '';
    return $self->_render_facets($fd, '');
}

sub _render_facets {
    my ($self, $fd, $indent) = @_;
    my $out = '';

    $out .= $self->_render_control($fd, $indent) if $fd->{control};
    $out .= $self->_render_plan($fd, $indent)    if $fd->{plan};
    $out .= $self->_render_assert($fd, $indent)  if $fd->{assert};
    $out .= $self->_render_parent($fd, $indent)  if $fd->{parent};
    $out .= $self->_render_info($fd, $indent)    if $fd->{info};
    $out .= $self->_render_errors($fd, $indent)  if $fd->{errors};
    $out .= $self->_render_about($fd, $indent)
        if $fd->{about} && !$out;
    $out .= $self->_render_harness_job($fd, $indent);

    return $out;
}

sub _render_control {
    my ($self, $fd, $indent) = @_;
    my $c   = $fd->{control};
    my $out = '';

    $out .= "${indent}HALT: " . ($c->{details} // '') . "\n"
        if defined $c->{halt};

    return $out;
}

sub _render_plan {
    my ($self, $fd, $indent) = @_;
    my $p   = $fd->{plan};
    my $out = '';

    if ($p->{none}) {
        $out .= "${indent}NO PLAN: " . ($p->{details} // '') . "\n";
    }
    elsif ($p->{skip}) {
        my $reason = $p->{details} // 'No reason given';
        $out .= "${indent}SKIP ALL: ${reason}\n";
    }
    else {
        $out .= "${indent}PLAN: Expected assertions: " . ($p->{count} // '?') . "\n";
    }

    return $out;
}

sub _render_assert {
    my ($self, $fd, $indent) = @_;
    my $a   = $fd->{assert};
    my $out = '';

    my $name = $a->{details} // '<UNNAMED ASSERTION>';
    my $tag;

    if ($fd->{amnesty} && @{$fd->{amnesty}}) {
        $tag = '! PASS !';
    }
    elsif ($a->{pass}) {
        $tag = 'PASS';
    }
    else {
        $tag = 'FAIL';
    }

    $out .= "${indent}${tag}: ${name}\n";

    # On failure without amnesty: append trace location (debug line).
    unless ($a->{pass} || $a->{no_debug} || ($fd->{amnesty} && @{$fd->{amnesty}})) {
        $out .= $self->_render_debug($fd, $indent);
    }

    # Amnesty entries (TODO / SKIP reasons).
    if ($fd->{amnesty} && @{$fd->{amnesty}}) {
        $out .= $self->_render_amnesty($fd, $indent);
    }

    return $out;
}

sub _render_debug {
    my ($self, $fd, $indent) = @_;
    my $trace = $fd->{trace};

    my $debug;
    if ($trace) {
        $debug = $trace->{details};
        if (!$debug && $trace->{frame}) {
            my $frame = $trace->{frame};
            $debug = "$frame->[1] line $frame->[2]";
        }
    }

    $debug //= '[No trace info available]';
    chomp $debug;

    return "${indent}DEBUG: ${debug}\n";
}

sub _render_amnesty {
    my ($self, $fd, $indent) = @_;
    my $out = '';
    my %seen;
    for my $am (@{$fd->{amnesty}}) {
        my $key = join '' => map { $_ // '' } @{$am}{qw/tag details/};
        next if $seen{$key}++;
        my $tag     = $am->{tag}     // 'AMNESTY';
        my $details = $am->{details} // '';
        $out .= "${indent}${tag}: ${details}\n";
    }
    return $out;
}

sub _render_parent {
    my ($self, $fd, $indent) = @_;
    my $p_data = $fd->{parent} or return '';

    my $out          = '';
    my $child_indent = $indent . '  ';

    for my $child (@{$p_data->{children} // []}) {
        my $child_fd = blessed($child) ? $child->facet_data : $child->{facet_data} // $child;
        $out .= $self->_render_facets($child_fd, $child_indent);
    }

    return $out;
}

sub _render_info {
    my ($self, $fd, $indent) = @_;
    my $out = '';

    for my $line (@{$fd->{info}}) {
        my $details = $line->{details} // '';
        if (ref $details) {
            require Data::Dumper;
            my $dumper = Data::Dumper->new([$details])->Indent(2)->Terse(1)->Useqq(1)->Sortkeys(1);
            $details = $dumper->Dump;
            chomp $details;
        }
        else {
            chomp $details;
        }
        my $tag = $line->{tag} // 'INFO';
        $out .= "${indent}${tag}: ${details}\n";
    }

    return $out;
}

sub _render_errors {
    my ($self, $fd, $indent) = @_;
    my $out = '';

    for my $err (@{$fd->{errors}}) {
        my $details = $err->{details} // '';
        if (ref $details) {
            require Data::Dumper;
            my $dumper = Data::Dumper->new([$details])->Indent(2)->Terse(1)->Useqq(1)->Sortkeys(1);
            $details = $dumper->Dump;
            chomp $details;
        }
        else {
            chomp $details;
        }
        my $tag = $err->{tag} // ($err->{fail} ? 'FATAL' : 'ERROR');
        $out .= "${indent}${tag}: ${details}\n";
    }

    return $out;
}

sub _render_about {
    my ($self, $fd, $indent) = @_;
    my $ab = $fd->{about};

    return '' if $ab->{no_display};
    return '' unless $ab->{details};

    my $type = 'ABOUT';
    if ($ab->{package}) {
        ($type = $ab->{package}) =~ s/^.*:://;
    }

    return "${indent}${type}: " . $ab->{details} . "\n";
}

sub _render_harness_job {
    my ($self, $fd, $indent) = @_;
    my $out = '';

    if (my $hl = $fd->{harness_job_launch}) {
        my $stamp = $hl->{stamp} // '';
        $out .= "${indent}HARNESS: Job Launched at ${stamp}\n";
    }

    if (my $hs = $fd->{harness_job_start}) {
        my $details = $hs->{details} // '';
        $out .= "${indent}HARNESS: ${details}\n";
    }

    if (my $hx = $fd->{harness_job_exit}) {
        my $details = $hx->{details} // '';
        $out .= "${indent}HARNESS: ${details}\n";
    }

    if (my $he = $fd->{harness_job_end}) {
        my $stamp = $he->{stamp} // '';
        $out .= "${indent}HARNESS: Job completed at ${stamp}\n";
    }

    return $out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Formatter::Txt - Plain-text event formatter

=head1 DESCRIPTION

A plain-text formatter that converts harness events into human-readable
lines. Inherits from L<App::Yath2::Formatter>.

Output is canonical: no color, no ANSI escape codes, no terminal-width
wrapping. Display policy (color, verbosity level, width) is the
responsibility of the renderer layer.

Facet rendering order: C<control>, C<plan>, C<assert> (with inline
C<trace>/C<amnesty>), C<parent> (recursive children indented 2 spaces),
C<info>, C<errors>, C<about> (fallback when nothing else produced output),
C<harness_job_launch> / C<harness_job_start> / C<harness_job_exit> /
C<harness_job_end>.

=head1 INTERFACE

=over 4

=item $bool = App::Yath2::Formatter::Txt->produces_artifact

Returns C<1>. This formatter produces stable plain-text output that is
safe to persist as a log artifact.

=item $bytes = $formatter->convert_item($item)

Convert a single event hashref to a plain-text byte string. The
following facets are handled:

=over 4

=item control

Emits a C<HALT:> line when the C<halt> key is present.

=item plan

Emits a C<PLAN:>, C<SKIP ALL:>, or C<NO PLAN:> line depending on
the plan type.

=item assert

Emits C<PASS:>, C<FAIL:>, or C<! PASS !:> followed by the assertion
name. On failure (without amnesty), also emits a C<DEBUG:> line from
the C<trace> facet. C<amnesty> entries (TODO/SKIP reasons) are appended
after the assert line.

=item parent

Recursively renders each child event in the C<children> list, indented
by two spaces. Indentation accumulates for nested subtests.

=item info

Each entry in the info array is emitted as C<< TAG: details >>, using the
entry's own C<tag> field (defaulting to C<INFO>).

=item errors

Each entry in the errors array is emitted as C<< TAG: details >>, using
the entry's C<tag> field (defaulting to C<FATAL> when C<fail> is set,
otherwise C<ERROR>).

=item about

Emitted only when no other facet produced output. Uses the short
package name as the tag, or C<ABOUT> as a fallback.

=item harness_job_launch / harness_job_start / harness_job_exit / harness_job_end

Job lifecycle markers emitted as C<HARNESS:> lines.

=back

Items with no recognised facets produce an empty string.

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

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
