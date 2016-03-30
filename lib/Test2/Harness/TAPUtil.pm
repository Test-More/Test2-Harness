package Test2::Harness::TAPUtil;
use strict;
use warnings;

our @EXPORT_OK = qw{
    parse_tap_line

    parse_tap_bail
    parse_tap_comment
    parse_tap_ok
    parse_tap_plan
};
use base 'Exporter';

use Test2::Harness::Event;

sub parse_tap_line {
    my ($from, $line) = @_;

    chomp($line);

    my ($nest, $str) = ($line =~ m/^(\s+)(.+)$/) ? (length($1), $2) : (0, $line);

    my @types = $from eq 'STDERR' ? (qw/comment/) : (qw/ok comment plan bail/);

    my ($e, @errors);
    for my $type (@types) {
        my $sub = __PACKAGE__->can("parse_tap_$type");
        ($e, @errors) = $sub->($from, $str);
        last if $e;
    }

    return unless $e;

    $e->set_parsed_from_line($line);
    $e->set_parsed_from_handle($from);
    $e->set_nested($nest);

    return($e, @errors);
}

sub parse_tap_comment {
    my ($from, $line) = @_;

    return unless $line =~ s/^# ?//;
    return Test2::Harness::Event->new(summary => $line);
}

sub parse_tap_plan {
    my ($from, $line) = @_;

    return unless $line =~ s/^1\.\.(\d+)//;
    my $max = $1;

    my ($directive, $reason);

    if ($max == 0) {
        if ($line =~ s/^\s*#\s*//) {
            if ($line =~ s/^(skip)\S*\s+//i) {
                $directive = uc($1);
                $reason = $line;
                $line = "";
            }
        }

        $directive ||= "SKIP";
        $reason    ||= "no reason given";
    }

    my $summary;
    if ($max || !$directive) {
        $summary = "Plan is $max assertions";
    }
    elsif($reason) {
        $summary = "Plan is '$directive', $reason";
    }
    else {
        $summary = "Plan is '$directive'";
    }

    my $event = Test2::Harness::Event->new(
        summary   => $summary,
        sets_plan => [$max, $directive, $reason],
    );

    return $event unless $line =~ m/\S/;
    return($event, "Extra characters after plan.");
}

sub parse_tap_bail {
    my ($from, $line) = @_;

    return unless $line =~ m/^Bail out!\b/;

    return Test2::Harness::Event->new(
        summary     => $line,
        terminate   => 255,
        global      => 1,
        causes_fail => 1,
    );
}

sub parse_tap_ok {
    my ($from, $line) = @_;

    my ($pass, $todo, $skip, $num, @errors);

    return unless $line =~ s/^(not )?ok\b//;
    $pass = !$1;

    push @errors => "'ok' is not immedietly followed by a space."
        if $line && !($line =~ s/^ //);

    if ($line =~ s/^(\s*)(\d+)\b//) {
        my $space = $1;
        $num = $2;

        push @errors => "Extra space between 'ok' and number."
            if length($space);

        push @errors => "No space after the test number."
            unless $line =~ s/^ //;
    }

    # Standard says that everything after the ok (except the number) is part of
    # the name. Most things add a dash between them, and I am deviating from
    # standards by stripping it and surrounding whitespace.
    $line =~ s/\s*-\s*//;

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

    $line =~ s/^\s+//;
    $line =~ s/\s+$//;
    my $summary = $line || "Nameless Assertion";

    if ($todo) {
        $summary .= " (TODO: $todo)";
    }
    elsif(defined $todo) {
        $summary .= " (TODO)";
    }

    if ($skip) {
        $summary .= " (SKIP: $skip)";
    }
    elsif(defined $todo) {
        $summary .= " (SKIP)";
    }

    my $event = Test2::Harness::Event->new(
        summary          => $summary,
        number           => $num,
        increments_count => 1,
        causes_fail      => ($pass || $todo) ? 0 : 1,
    );

    return($event, @errors);
}

1;
