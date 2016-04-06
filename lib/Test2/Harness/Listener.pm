package Test2::Harness::Listener;
use strict;
use warnings;

use Test2::Util::HashBase qw/color verbose jobs order parallel gidx clear/;
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

    $| = 1;
}

sub find_color {
    my $self = shift;
    return '' unless $self->{+COLOR};
    Term::ANSIColor::color(@_);
}

sub listen {
    my $self = shift;

    sub { $self->process(@_) }
};

sub process {
    my $self = shift;
    my ($j, $fact, $no_buf, $last) = @_;

    my $jobs = $self->{+JOBS};
    my $job = $jobs->{$j} || $self->init_job($j);

    $no_buf ||= $fact->nested == 1 if $fact->result;

    $self->render($j, $fact, $no_buf, $last);

    if ($fact->result && $no_buf) {
        for my $f (@{$fact->result->facts}) {
            $self->process($j, $f, 1, $f == $fact->result->facts->[-1]);
        }
    }

    $self->end_job($j) if $fact->result && !$fact->nested;
}

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

sub render {
    my $self = shift;
    my ($j, $fact, $no_buf, $last) = @_;

    my $jobs = $self->{+JOBS};

    my ($prefix, $color) = $self->highlight($fact);
    return unless $prefix;

    if ($self->{+CLEAR}) {
        print "\e[K";
        $self->{+CLEAR} = 0;
    }

    my $reset = $RESET;
    my $bold  = $BOLD;

    if($self->{+COLOR}) {
        my $allow = $COLORS[$self->{+COLOR} || 0];
        $color = '' unless $allow->{$color};
    }
    else {
        $color = '';
        $reset = '';
        $bold  = '';
    }

    my ($tidx, @tree) = $self->tree($j, $fact);

    my $summary = $fact->summary;
    $summary =~ s/^[\n\r]+//g;

    my $end = "\n";
    my $nest = '';

    if(my $nested = $fact->nested) {
        if ($no_buf) {
            if ($fact->result) {
                if ($nested > 1) {
                    $nest = '| ' x ($nested - 2);
                    $nest .= "+-";
                }
            }
            elsif ($last) {
                $nest = '| ' x ($nested - 1);
                $nest .= "^ ";
            }
            else {
                $nest = '| ' x $nested;
            }
        }
        else {
            return unless -t STDOUT;
            $nest = '>' x $nested;
            $nest .= " ";
            $end = "\r";
            $self->{+CLEAR} = 1;
        }
    }

    for my $ti (0 .. $#tree) {
        if ($ti == $tidx) {
            my $jcolor = $jobs->{$j}->{color};
            my @lines = grep {$_} split /[\n\r]+/, $summary;
            @lines = ('') unless @lines;
            print " ${bold}[${reset}${color}${prefix}${reset}${bold}]${reset}  $tree[$ti]  ${jcolor}${nest}${reset}${color}$_${reset}$end" for @lines;
        }
        else {
            print "           $tree[$ti]\n";
        }
    }
}

sub tree {
    my $self = shift;
    my ($j, $fact) = @_;

    my $reset = $self->find_color('reset');
    my $bold  = $self->find_color('bold bright_white');
    my $jobs  = $self->{+JOBS};
    my $order = $self->{+ORDER};

    my (@before, $it, @after);

    if ($fact->start) {
        push @before => join(' ' => map {$_ eq $j ? () : "$jobs->{$_}->{color}|$reset"} @$order);
    }
    elsif($fact->result && !$fact->nested) {
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

sub highlight {
    my $self = shift;
    my ($fact) = @_;

    return (" FILE ", $FILE) if $fact->start;

    if ($fact->event) {
        return ("NOT OK", $FAIL) if $fact->causes_fail;
        return (" DIAG ", $DIAG) if $fact->diagnostics;

        return unless $self->{+VERBOSE};
        return ("  OK  ", $PASS) if $fact->increments_count;
        return (" PLAN ", $PLAN) if $fact->sets_plan;
        return (" NOTE ", $NOTE);
    }

    if (defined $fact->output) {
        my $handle = $fact->parsed_from_handle || "";

        return ("STDERR", $DIAG)
            if $handle eq 'STDERR';

        return (" DIAG ", $DIAG) if $fact->diagnostics;

        return unless $self->{+VERBOSE};
        return ("STDOUT", $NOTE);
    }

    if ($fact->result) {
        return ("FAILED", $FAILED) if $fact->causes_fail;
        return unless $self->{+VERBOSE} || !$fact->nested;
        return ("PASSED", $PASSED);
    }

    return unless $self->{+VERBOSE};
    return ("PARSER", $PARSER) if $fact->parse_error;

    return ("UNKNWN", '');
}

1;
