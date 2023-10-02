package Test2::Formatter::Test2::Composer;
use strict;
use warnings;

our $VERSION = '1.000155';

use Scalar::Util qw/blessed/;
use List::Util qw/first/;

sub new {
    my $class = shift;
    return bless({}, $class);
}

sub render_one_line {
    my $class = shift;
    my $in   = shift;
    my $f    = blessed($in) ? $in->facet_data : $in;

    return [$f->{render}->[0]->{facet}, uc($f->{render}->[0]->{tag}), $f->{render}->[0]->{details}]
        if $f->{render} && @{$f->{render}};

    return (($class->halt($f))[0]) if $class->{control} && defined $class->{control}->{halt};

    for my $type (qw/assert errors plan info times about/) {
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

    return [map {[$_->{facet}, uc($_->{tag}), $_->{details}]} @{$f->{render}}]
        if $f->{render} && @{$f->{render}};

    my @out;

    push @out => $class->render_control($f, %params) if $f->{control};
    push @out => $class->render_plan($f) if $f->{plan};

    if ($f->{assert}) {
        push @out => $class->render_assert($f);
        push @out => $class->render_debug($f) unless $f->{assert}->{pass} || $f->{assert}->{no_debug};
        push @out => $class->render_amnesty($f) if $f->{amnesty} && @{$f->{amnesty}};
    }

    push @out => $class->render_info($f)   if $f->{info};
    push @out => $class->render_errors($f) if $f->{errors};

    push @out => $class->render_about($f)
        if $f->{about} && !(@out || first { $f->{$_} } qw/stop plan info nest assert/);

    return \@out;
}

sub render_super_verbose {
    my $class = shift;
    my ($in) = @_;

    my $out = $class->render_verbose($in, super_verbose => 1);

    my $f = blessed($in) ? $in->facet_data : $in;

    push @$out => $class->render_launch($f)  if $f->{harness_job_launch};
    push @$out => $class->render_start($f)   if $f->{harness_job_start};
    push @$out => $class->render_exit($f)    if $f->{harness_job_exit};
    push @$out => $class->render_end($f)     if $f->{harness_job_end};

    unless (@$out) {
        my ($name, $fallback);
        for my $k (sort keys %$f) {
            my $v = $f->{$k};

            # Fallback should be longest harness* facet name
            $fallback = $k if $k =~ m/harness/ && (!$fallback || length($fallback) < length($k));

            my $list = ref($v) eq 'ARRAY' ? $v : [$v];
            for my $i (@$list) {
                next unless ref($i);
                last if $name = $i->{details};
            }
        }

        $name //= $fallback // join ', ' => sort keys %$f;

        push @$out => ['harness', 'HARNESS', $name];
    }

    return $out;
}

sub render_launch {
    my $class = shift;
    my ($f) = @_;

    return ['harness', 'HARNESS', 'Job Launched at ' . $f->{harness_job_launch}->{stamp}];
}

sub render_start {
    my $class = shift;
    my ($f) = @_;

    return ['harness', 'HARNESS', $f->{harness_job_start}->{details}];
}

sub render_exit {
    my $class = shift;
    my ($f) = @_;

    return ['harness', 'HARNESS', $f->{harness_job_exit}->{details}];
}

sub render_end {
    my $class = shift;
    my ($f) = @_;

    return ['harness', 'HARNESS', "Job completed at " . $f->{harness_job_end}->{stamp}];
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
    my $in   = shift;
    my $f    = blessed($in) ? $in->facet_data : $in;

    if ($f->{render} && @{$f->{render}}) {
        my @show = grep { $SHOW_BRIEF_TAGS{uc($_->{tag})} || $SHOW_BRIEF_FACETS{lc($_->{facet})} } @{$f->{render}};
        return [map { [$_->{facet}, uc($_->{tag}), $_->{details}] } @show];
    }

    my @out;

    push @out => $class->render_control($f) if $f->{control};

    if ($f->{assert} && !$f->{assert}->{pass} && !$f->{amnesty}) {
        push @out => $class->render_assert($f);
        push @out => $class->render_debug($f) unless $f->{assert}->{no_debug};
    }

    if ($f->{info}) {
        my $if = {%$f, info => [grep { $_->{debug} || $_->{important} } @{$f->{info}}]};
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

    return ['assert', 'FAIL', $name]
}

sub render_amnesty {
    my $class = shift;
    my ($f) = @_;

    my %seen;
    return map {
        $seen{join '' => @{$_}{qw/tag details/}}++
            ? ()
            : ['amnesty', $_->{tag}, $_->{details}]
    } @{$f->{amnesty}};
}

sub render_debug {
    my $class = shift;
    my ($f) = @_;

    my $name  = $f->{assert}->{details};
    my $trace = $f->{trace};

    my $debug;
    if ($trace) {
        $debug = $trace->{details};
        if(!$debug && $trace->{frame}) {
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

        my $msg;
        if (ref($details)) {
            require Data::Dumper;
            my $dumper = Data::Dumper->new([$details])->Indent(2)->Terse(1)->Useqq(1)->Sortkeys(1);
            chomp($msg = $dumper->Dump);
        }
        else {
            chomp($msg = $details);
        }

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
        my $type = $f->{about}->{package};
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

        my $msg;
        if (ref($details)) {
            require Data::Dumper;
            my $dumper = Data::Dumper->new([$details])->Indent(2)->Terse(1)->Useqq(1)->Sortkeys(1);
            chomp($msg = $dumper->Dump);
        }
        else {
            chomp($msg = $details);
        }

        my $tag = $_->{tag} || ($_->{fail} ? 'FATAL' : 'ERROR');

        ['error', $tag, $details]
    } @{$f->{errors}};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Formatter::Test2::Composer - Compose output components from event facets

=head1 DESCRIPTION

This is used by L<Test2::Formatter::Test2> to turn events into output
components. This logic lives here instead of in the formatter because it is
also used by L<Test2::Harness::UI>. Other tools may also find this conversion
useful.

=head1 SYNOPSIS

    use Test2::Formatter::Test2::Composer;

    # Note, all methods are class methods, this is just here for convenience.
    my $comp = Test2::Formatter::Test2::Composer->new();

    my $out = $comp->render_one_line($event);
    my ($facet_name, $tag_string, $text_for_humans) = @$out;
    ...

    for my $line ($comp->render_verbose($event)) {
        my ($facet_name, $tag_string, $text_for_humans) = @$line;
        ...,
    }

=head1 METHODS

All methods are class methods, but they also work just fine on a blessed
instance. There is no benefit to a blessed instance, but you can create one for
convenience if it makes you more comfortable.

=over 4

=item $inst = $class->new()

Create a blessed instance. This is here for convenience only. All methods are
class methods.

=item $arrayref = $class->render_one_line($event)

=item $arrayref = $class->render_one_line(\%facet_data)

    my $out = $comp->render_one_line($event);
    my ($facet_name, $tag_string, $text_for_humans) = @$out;

This will return a single line of output from the event, even if the event
would normally return multiple lines.

In order of priority:

=over 4

=item Custom 'render' facet

=item Control 'halt' facet (bail-out)

=item Assertion (pass/fail)

=item Error message

=item Plan

=item Info (note/diag)

=item Timing data

=item About

=back

=item @lines = $class->render_verbose($event, %control_params)

=item @lines = $class->render_verbose(\%facet_data, %control_params)

This will verbosely render any event. The C<%control_params> are passed
directly to C<render_control()> and are not used for anything else.

    for my $line ($comp->render_verbose($event)) {
        my ($facet_name, $tag_string, $text_for_humans) = @$line;
        ...,
    }

=item @lines = $class->render_super_verbose($event)

=item @lines = $class->render_super_verbose(\%facet_data)

This is even more verbose than C<render_verbose()> because it produces output
lines even for facets that should normally not be seen, things that would
usually be considered noise.

This is mainly useful for tools that allow deep inspection of log files.

=back

=head2 FACET RENDERERS

With exception of C<render_control()> these are all the same. These all take
C<\%facet_data> as their only argument, and return a list of line-arrayrefs
C<[$facet, $tag, $text_for_humans]>.

=over 4

=item @lines = $class->render_control(\%facet_data, super_verbose => $bool)

This specific one is special in that it can take an extra argument. This
argument is used to toggle between super_verbose and regular verbosity. No
other facet renderer needs this toggle. If omitted it defaults to not being
super verbose.

=item @lines = $class->render_launch(\%facet_data)

=item @lines = $class->render_start(\%facet_data)

=item @lines = $class->render_exit(\%facet_data)

=item @lines = $class->render_end(\%facet_data)

=item @lines = $class->render_brief(\%facet_data)

=item @lines = $class->render_plan(\%facet_data)

=item @lines = $class->render_assert(\%facet_data)

=item @lines = $class->render_amnesty(\%facet_data)

=item @lines = $class->render_debug(\%facet_data)

=item @lines = $class->render_info(\%facet_data)

=item @lines = $class->render_about(\%facet_data)

=item @lines = $class->render_errors(\%facet_data)

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
