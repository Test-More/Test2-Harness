package Test2::Formatter::Test2::Composer;
use strict;
use warnings;

our $VERSION = '0.001072';

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
    my $in   = shift;
    my $f    = blessed($in) ? $in->facet_data : $in;

    return [map {[$_->{facet}, uc($_->{tag}), $_->{details}]} @{$f->{render}}]
        if $f->{render} && @{$f->{render}};

    my @out;

    push @out => $class->render_halt($f) if $f->{control} && defined $f->{control}->{halt};
    push @out => $class->render_plan($f) if $f->{plan};

    if ($f->{assert}) {
        push @out => $class->render_assert($f);
        push @out => $class->render_debug($f) unless $f->{assert}->{pass} || $f->{assert}->{no_debug};
        push @out => $class->render_amnesty($f) if $f->{amnesty} && !$f->{assert}->{pass};
    }

    push @out => $class->render_info($f)   if $f->{info};
    push @out => $class->render_errors($f) if $f->{errors};
    push @out => $class->render_times($f)  if $f->{times};
    push @out => $class->render_memory($f) if $f->{memory};

    push @out => $class->render_about($f)
        if $f->{about} && !(@out || first { $f->{$_} } qw/stop plan info nest assert/);

    return \@out;
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

    push @out => $class->render_halt($f) if $f->{control} && defined $f->{control}->{halt};

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

sub render_times {
    my $class = shift;
    my ($f) = @_;

    return ['times', 'TIME', $f->{about}->{details}];
}

sub render_memory {
    my $class = shift;
    my ($f) = @_;

    return ['memory', 'MEMORY', $f->{memory}->{details}];
}


sub render_halt {
    my $class = shift;
    my ($f) = @_;

    return ['control', 'HALT', $f->{control}->{details}];
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

    return ['assert', 'PASS', $name]
        if $f->{assert}->{pass};

    return ['assert', '! PASS !', $name]
        if $f->{amnesty} && @{$f->{amnesty}};

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
        my $details = $_->{details} || '';

        my $msg;
        if (ref($details)) {
            require Data::Dumper;
            my $dumper = Data::Dumper->new([$details])->Indent(2)->Terse(1)->Useqq(1)->Sortkeys(1);
            chomp($msg = $dumper->Dump);
        }
        else {
            chomp($msg = $details);
        }

        ['info', $_->{tag}, $details]
    } @{$f->{info}};
}

sub render_about {
    my $class = shift;
    my ($f) = @_;

    return if $f->{about}->{no_display};
    return unless $f->{about} && $f->{about}->{package} && $f->{about}->{details};

    my $type = $f->{about}->{package};

    return ['info', $type, $f->{about}->{details}];
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

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
