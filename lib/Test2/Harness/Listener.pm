package Test2::Harness::Listener;
use strict;
use warnings;

use Test2::Util::HashBase qw/color verbose jobs order counter parallel gidx clear/;
use Term::ANSIColor();
use List::Util qw/first shuffle/;
use Scalar::Util qw/blessed/;
use Time::HiRes qw/sleep/;

sub HEADER_COUNT() { 10 }

my @GRAPH_COLORS = map {Term::ANSIColor::color($_)} qw/blue green cyan red yellow magenta/;

my $FAIL   = Term::ANSIColor::color('bold red');
my $PASS   = Term::ANSIColor::color('green');
my $FAILED = Term::ANSIColor::color('bold red');
my $PASSED = Term::ANSIColor::color('bold green');
my $DIAG   = Term::ANSIColor::color('yellow');
my $NOTE   = Term::ANSIColor::color('blue');
my $PLAN   = Term::ANSIColor::color('cyan');
my $PARSER = Term::ANSIColor::color('magenta');
my $RESET  = Term::ANSIColor::color('reset');
my $BOLD   = Term::ANSIColor::color('bold white');
my $FILE   = Term::ANSIColor::color('bold white');

my @COLORS = (
    {},
    { map { $_ => 1 } $DIAG, $FAIL, $FAILED, $PARSER, $PASS, $BOLD, $PASSED },
    { map { $_ => 1 } $FAIL, $PASS, $FAILED, $PASSED, $DIAG, $NOTE, $PLAN, $PARSER, $BOLD},
);

sub init {
    my $self = shift;
    $self->{+JOBS}   = {};
    $self->{+ORDER}  = [];

    $self->{+GIDX}    = 0;
    $self->{+COUNTER} = 0;

    $| = 1;
}

sub find_color {
    my $self = shift;
    return '' unless $self->{+COLOR};
    Term::ANSIColor::color(@_);
}

sub listen {
    my $self = shift;

    my $jobs = $self->{+JOBS};

    sub {
        my ($j, $dest, $thing) = @_;

        my $job = $jobs->{$j} || $self->init_job($j);

        $self->render($j, $dest, $thing);

        $self->end_job($j) if $dest eq 'subtests' && !$thing->nested;
    }
};

sub init_job {
    my $self = shift;
    my ($j) = @_;

    my $jobs   = $self->{+JOBS};
    my $order  = $self->{+ORDER};

    my $color = '';
    my $reset = '';

    if ($self->{+COLOR}) {
        my %used = map {( $jobs->{$_}->{color} => 1 )} @$order;
        my $gidx = \($self->{+GIDX});

        my $now = $$gidx;
        until($color) {
            $color = $GRAPH_COLORS[$$gidx]
                unless $used{$GRAPH_COLORS[$$gidx]};
            ${$gidx}++;
            ${$gidx} = 0 if ${$gidx} > $#GRAPH_COLORS;
            last if $$gidx == $now;
        }

        $color ||= first { !$used{$_} } @GRAPH_COLORS;
        ($color) = shuffle(@GRAPH_COLORS) unless $color;

        $reset = $self->find_color('reset');
    }

    $jobs->{$j} = {color => $color};
    push @$order => $j;
}

sub end_job {
    my $self = shift;
    my ($j) = @_;

    my $order = $self->{+ORDER};
    @$order = grep { $_ ne $j } @$order;
    delete $self->{+JOBS}->{$j};
}

sub highlight {
    my $self = shift;
    my ($dest, $thing) = @_;

    return (" FILE ", $FILE) if $dest eq 'START';

    if ($dest eq 'events') {
        return ("NOT OK", $FAIL) if $thing->causes_fail;
        return (" DIAG ", $DIAG) if $thing->diagnostics;

        return unless $self->{+VERBOSE};
        return ("  OK  ", $PASS) if $thing->increments_count;
        return (" PLAN ", $PLAN) if $thing->sets_plan;
        return (" NOTE ", $NOTE);
    }

    return ("STDERR", $DIAG) if $dest eq 'err_lines';

    if ($dest eq 'out_lines') {
        return unless $self->{+VERBOSE};
        return ("STDOUT", $NOTE);
    }

    if ($dest eq 'subtests') {
        return ("FAILED", $FAILED) unless $thing->passed;
        return unless $self->{+VERBOSE} || !$thing->nested;
        return ("PASSED", $PASSED);
    }

    return unless $self->{+VERBOSE};
    return ("PARSER", $PARSER) if $dest eq 'parse_errors';

    return (sprintf("[%-6.6s]", $dest), '');
}

sub summary {
    my $self = shift;
    my ($dest, $thing) = @_;

    return "$thing" if $dest eq 'START';

    return $thing->summary || ""
        if $dest eq 'events';

    return $thing if $dest eq 'err_lines';
    return $thing if $dest eq 'out_lines';

    if ($dest eq 'subtests') {
        return $thing->file unless $thing->nested;
        return '';
    }

    return $thing;
}

sub render {
    my $self = shift;
    my ($j, $dest, $thing) = @_;

    my $jobs = $self->{+JOBS};

    my ($prefix, $color) = $self->highlight($dest, $thing);
    return unless $prefix;

    if ($self->{+CLEAR}) {
        print "\e[K";
        $self->{+CLEAR} = 0;
    }

    my $reset = $RESET;
    my $bold = $BOLD;

    if($self->{+COLOR}) {
        my $allow = $COLORS[$self->{+COLOR} || 0];
        $color = '' unless $allow->{$color};
    }
    else {
        $color = '';
        $reset = '';
        $bold  = '';
    }

    my ($tidx, @tree) = $self->tree($j, $dest, $thing);

    chomp(my $summary = $self->summary($dest, $thing));
    $summary =~ s/^[\n\r]+//g;

    my $end = "\n";
    my $nested = blessed($thing) && $thing->can('nested') ? $thing->nested : 0;
    my $nest = '';
    if ($nested) {
        my $is_res = $thing->isa('Test2::Harness::Result');
        unless($is_res) {
            $nest = '>' x $nested;
            $nest .= " ";
            $end = "\r";
            $self->{+CLEAR} = 1;
        }
    }
    for my $ti (0 .. $#tree) {
        if ($ti == $tidx) {
            my @lines = split /\n/, $summary;
            @lines = ('') unless @lines;
            print " ${bold}[${reset}${color}${prefix}${reset}${bold}]${reset}  $tree[$ti]  ${nest}${color}$_${reset}$end" for @lines;
        }
        else {
            print "           $tree[$ti]\n";
        }
    }

    #my $last = $jobs->{$j}->{last};
    #if ($last == $self->{+COUNTER}) {
    #    $jobs->{$j}->{seq}++;
    #}
    #else {
    #    $jobs->{$j}->{seq} = 0; # :-(
    #}
    #$jobs->{$j}->{last} = $self->{+COUNTER} += 1;
}

sub tree {
    my $self = shift;
    my ($j, $dest, $thing) = @_;

    my $reset = $self->find_color('reset');
    my $bold  = $self->find_color('bold bright_white');
    my $jobs  = $self->{+JOBS};
    my $order = $self->{+ORDER};

    my (@before, $it, @after);

    if ($dest eq 'START') {
        push @before => join(' ' => map {$_ eq $j ? () : "$jobs->{$_}->{color}|$reset"} @$order);
    }
    elsif($dest eq 'subtests' && !$thing->nested) {
        my $tree = '';
        my $seen = 0;
        for my $o (@$order) {
            if ($o eq $j) {
                $tree .= " ";
                $seen++;
                next;
            }
            $tree .= " " if length($tree) && $tree =~ m/\S/;
            $tree .= $jobs->{$o}->{color};
            $tree .= $seen ? "/" : "|";
            $tree .= $reset;
        }
        push @after => $tree;
    }

    $it = join(' ' => map {($_ eq $j ? "${bold}*" : "$jobs->{$_}->{color}|") . $reset} @$order);

    my $idx = @before;
    return ($idx, @before, $it, @after);
}

1;
