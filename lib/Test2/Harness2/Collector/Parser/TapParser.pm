package Test2::Harness2::Collector::Parser::TapParser;
use strict;
use warnings;

our $VERSION = '2.000011';

use Importer 'Importer' => 'import';

our @EXPORT_OK = qw{
    parse_stdout_tap
    parse_stderr_tap
    parse_tap_line
};

sub parse_stdout_tap {
    my ($line) = @_;
    my $facet_data = __PACKAGE__->_parse_tap_line($line) or return undef;
    $facet_data->{from_tap} = {source => 'STDOUT', details => $line};
    return $facet_data;
}

sub parse_stderr_tap {
    my ($line) = @_;

    # STDERR only has comments
    return unless $line =~ m/^\s*#/;

    my $facet_data = __PACKAGE__->parse_tap_comment($line, no_nest => 1) or return undef;
    $facet_data->{info}->[-1]->{tag}   = 'DIAG';
    $facet_data->{info}->[-1]->{debug} = 1;
    $facet_data->{from_tap}            = {source => 'STDERR', details => $line};

    return $facet_data;
}

sub parse_tap_line {
    my ($line) = @_;
    return __PACKAGE__->_parse_tap_line($line);
}

sub _parse_tap_line {
    my $class = shift;
    my ($line) = @_;
    chomp($line);

    my ($lead, $lead_len, $nest, $str) = ('', 0, 0, $line);
    if ($line =~ m/^(\s+)\S/) {
        $lead = $1;
        $str =~ s/^\Q$lead\E//mg;

        $lead =~ s/\t/    /g;
        $lead_len = length($lead);

        # indentation other than 0 or a multiple of 4 spaces... not an event
        return undef if $lead_len % 4;

        $nest = $lead_len / 4;
    }

    my @types = qw/buffered_subtest comment plan bail version/;
    for my $type (@types) {
        my $sub        = "parse_tap_$type";
        my $facet_data = $class->$sub($str) or next;
        $facet_data->{trace}->{nested}     = $nest;
        $facet_data->{hubs}->[0]->{nested} = $nest;
        return $facet_data;
    }

    return undef;
}

sub parse_tap_buffered_subtest {
    my $class = shift;
    my ($line) = @_;

    # End of a buffered subtest.
    return {parent => {}, harness => {subtest_end => 1}} if $line =~ m/^\}\s*$/;

    my $facet_data = $class->parse_tap_ok($line) or return undef;
    return $facet_data unless $facet_data->{assert}->{details} =~ s/\s*\{\s*$//g;

    $facet_data->{parent} = {
        details => $facet_data->{assert}->{details},
    };
    $facet_data->{harness}->{subtest_start} = 1;

    return $facet_data;
}

sub parse_tap_ok {
    my $class = shift;
    my ($line) = @_;

    my ($pass, $todo, $skip, $num, @errors);

    return undef unless $line =~ s/^(not )?ok\b//;
    $pass = !$1;

    push @errors => "'ok' is not immediately followed by a space."
        if $line && !($line =~ m/^ /);

    if ($line =~ s/^(\s*)(\d+)\b//) {
        my $space = $1;
        $num = $2;

        push @errors => "Extra space after 'ok'"
            if length($space) > 1;
    }

    # Not strictly compliant, but compliant with what Test-Simple does...
    # Standard does not have a todo & skip.
    if ($line =~ s/#\s*(todo & skip|todo|skip)(.*)$//i) {
        my ($directive, $reason) = ($1, $2);

        push @errors => "No space before the '#' for the '$directive' directive."
            unless $line =~ s/\s+$//;

        push @errors => "No space between '$directive' directive and reason."
            if $reason && !($reason =~ s/^\s+//);

        $skip = $reason if $directive =~ m/skip/i;
        $todo = $reason if $directive =~ m/todo/i;
    }

    # Standard says that everything after the ok (except the number) is part of
    # the name. Most things add a dash between them, and I am deviating from
    # standards by stripping it and surrounding whitespace.
    $line =~ s/\s*-\s*//;

    $line =~ s/^\s+//;
    $line =~ s/\s+$//;

    my $is_subtest = ($line =~ m/^Subtest:\s*(.*)$/) ? ($1 or 1) : undef;

    my $facet_data = {
        assert => {
            pass     => $pass,
            no_debug => 1,
            details  => $line,
            defined $num ? (number => $num) : (),
        },
    };

    $facet_data->{parent} = {
        details => $is_subtest,
    } if defined $is_subtest;

    push @{$facet_data->{amnesty}} => {
        tag     => 'SKIP',
        details => $skip,
    } if defined $skip;

    push @{$facet_data->{amnesty}} => {
        tag     => 'TODO',
        details => $todo,
    } if defined $todo;

    push @{$facet_data->{info}} => {
        details => $_,
        debug   => 1,
        tag     => 'PARSER',
    } for @errors;

    return $facet_data;
}

sub parse_tap_version {
    my $class = shift;
    my ($line) = @_;

    return undef unless $line =~ m/^TAP version\s/;

    return {
        about => {
            details => $line,
        },
        info => [
            {
                tag     => 'INFO',
                debug   => 0,
                details => $line,
            }
        ],
    };
}

sub parse_tap_plan {
    my $class = shift;
    my ($line) = @_;

    return undef unless $line =~ s/^1\.\.(\d+)//;
    my $max = $1;

    my ($directive, $reason) = ("", "");

    if ($max == 0) {
        if ($line =~ s/^\s*#\s*//) {
            if ($line =~ s/^(skip)\S*\s*//i) {
                $directive = uc($1);
                $reason    = $line;
                $line      = "";
            }
        }

        $directive ||= "SKIP";
        $reason    ||= "no reason given";
    }

    my $facet_data = {
        plan => {
            count   => $max,
            skip    => ($directive eq 'SKIP') ? 1 : 0,
            details => $reason,
        }
    };

    push @{$facet_data->{info}} => {
        details => 'Extra characters after plan.',
        debug   => 1,
        tag     => 'PARSER',
    } if $line =~ m/\S/;

    return $facet_data;
}

sub parse_tap_bail {
    my $class = shift;
    my ($line) = @_;

    return undef unless $line =~ m/^Bail out!\s*(.*)$/;

    return {
        control => {
            halt    => 1,
            details => $1,
        }
    };
}

sub parse_tap_comment {
    my $class = shift;
    my ($line, %params) = @_;

    return undef unless $line =~ m/^\s*#/;

    $line =~ s/^\s*# ?//msg unless $params{no_nest};

    return {
        info => [
            {
                details => $line,
                tag     => 'NOTE',
                debug   => 0,
            }
        ]
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Parser::TapParser - Produce event facets from a line of TAP.

=head1 DESCRIPTION

Turns individual lines of TAP output into L<Test2::Event> facet data hashes
that can later be rehydrated into events.

TAP was designed as a human-readable line protocol, not as a round-trip
serialization for L<Test2> events, so the C<< Test2 -> TAP >> direction is
lossy: anything richer than TAP can express (structured info, multiple
assertions per event, custom facets, etc.) is flattened. This parser does the
best it can on the way back: it recognizes the common TAP line shapes and
maps them onto the corresponding facets.

All parsing is line-based and stateless. Callers read one line at a time
(without the trailing newline) and receive either a facet data hashref or
C<undef> if the line does not look like a recognizable TAP construct.

=head2 What is recognized

The parser handles the following TAP constructs:

=over 4

=item Plan lines

C<1..N>, including the skip-everything form
C<1..0 # SKIP reason>. Emits a C<plan> facet with C<count>, a boolean C<skip>,
and any C<details>. If anything follows the plan an B<PARSER> info facet is
attached noting extra characters.

=item Assertions

C<ok N - name> / C<not ok N - name>, with optional C<# TODO reason>,
C<# SKIP reason>, and C<# TODO & SKIP reason> directives. Emits an C<assert>
facet (C<pass>, C<number>, C<details>, C<no_debug>), plus C<amnesty> entries
for any TODO or SKIP directive. Parser complaints (missing space after
C<ok>, extra space after C<ok>, missing space before C<#>, missing space
between the directive and reason) are attached as B<PARSER> info facets.

=item Buffered subtests

The opening line C<ok N - Subtest: NAME {> sets C<harness.subtest_start> and
attaches a C<parent> facet with C<details> set to the subtest name. The
closing line C<}> sets C<harness.subtest_end>.

=item Comments

Lines starting with C<#> become C<info> facets. On STDOUT they are tagged as
C<NOTE>. On STDERR (via C<parse_stderr_tap>) they are tagged as C<DIAG> and
marked as debug.

=item Bail out

C<Bail out! REASON> emits a C<control> facet with C<halt = 1> and the reason
as C<details>.

=item TAP version

C<TAP version N> emits an C<about> facet plus an C<INFO> info entry.

=back

=head2 Nesting / indentation

Lines may be indented to indicate subtest nesting. Each level of nesting is
exactly four spaces; tabs are counted as four spaces for this purpose.
Indentation that is not a multiple of four columns is B<not> treated as TAP
and C<undef> is returned. When a line is recognized, the resulting facet data
has C<trace.nested> and C<hubs[0].nested> set to the nesting depth (0 for
top-level, 1 for one level of indent, and so on).

=head2 Non-TAP input

If a line does not match any recognized TAP construct C<undef> is returned.
Callers can use this as a cue to treat the line as raw stream output instead
(see L<Test2::Harness2::Collector::Parser::IOParser::Stream> for an example).

=head1 SYNOPSIS

    use Test2::Harness2::Collector::Parser::TapParser qw{
        parse_tap_line
        parse_stdout_tap
        parse_stderr_tap
    };

    # Plan
    my $fd = parse_tap_line("1..3");
    # $fd->{plan}{count} == 3

    # Assertion
    $fd = parse_tap_line("not ok 2 - oh no # TODO fix me");
    # $fd->{assert}{pass}   eq F()
    # $fd->{assert}{number} == 2
    # $fd->{amnesty}[0]{tag} eq 'TODO'

    # Comment on stdout -> NOTE
    $fd = parse_stdout_tap("# a note");
    # $fd->{info}[0]{tag} eq 'NOTE'
    # $fd->{from_tap}{source} eq 'STDOUT'

    # Comment on stderr -> DIAG
    $fd = parse_stderr_tap("# something went wrong");
    # $fd->{info}[-1]{tag} eq 'DIAG'
    # $fd->{from_tap}{source} eq 'STDERR'

    # Non-TAP line
    my $not_tap = parse_tap_line("hello world");  # undef

=head1 EXPORTS

Nothing is exported by default. All exports are opt-in via L<Importer>.

=over 4

=item $facet_data = parse_tap_line($line)

Parse a single line of TAP as if it came from STDOUT, returning the facet
data hashref or C<undef> for non-TAP input. Comments are turned into C<NOTE>
info entries. This form does B<not> attach a C<from_tap> facet; prefer
C<parse_stdout_tap> or C<parse_stderr_tap> when you want the source stream
recorded on the event.

=item $facet_data = parse_stdout_tap($line)

Same as C<parse_tap_line>, plus a C<from_tap> facet with C<source = STDOUT>
and C<details = $line> recording the original line verbatim.

=item $facet_data = parse_stderr_tap($line)

Parse a line of TAP from STDERR. B<Only> comment lines (lines matching
C</^\s*#/>) are parsed; anything else returns C<undef>. The sole C<info> entry
produced is tagged as C<DIAG> and marked C<debug = 1>. A C<from_tap> facet is
attached with C<source = STDERR>.

=back

=head1 CLASS METHODS

The helpers below are used internally by C<parse_tap_line> and its
relatives. They are documented because they may be useful for custom parsers
that want to recognize only a subset of TAP. Each returns either a facet data
hashref or C<undef>, and none of them attach a C<from_tap> facet or
C<trace>/C<hubs> nesting information -- those are added by the top-level
entry points.

=over 4

=item $fd = $class->parse_tap_ok($line)

Parse an C<ok>/C<not ok> line, including TODO/SKIP directives and the
buffered-subtest opener form.

=item $fd = $class->parse_tap_buffered_subtest($line)

Parse buffered-subtest openers (C<ok ... Subtest: NAME {>) and closers
(C<}>). Falls back to C<parse_tap_ok> when the line is an ordinary assertion.

=item $fd = $class->parse_tap_plan($line)

Parse a C<1..N> plan, including the skip-everything form.

=item $fd = $class->parse_tap_bail($line)

Parse a C<Bail out!> line.

=item $fd = $class->parse_tap_comment($line, %params)

Parse a comment line (C<#> prefix) into a C<NOTE> info facet. Pass
C<< no_nest => 1 >> to preserve the original indentation and leading C<#>
in the details (used by C<parse_stderr_tap>, which wants the raw line
preserved for diag output).

=item $fd = $class->parse_tap_version($line)

Parse a C<TAP version N> preamble.

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
