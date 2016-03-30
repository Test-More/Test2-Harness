package Test2::Harness::Parser;
use strict;
use warnings;

use Carp qw/croak/;

use Test2::Harness::Event;
use Test2::Harness::Result;

use Test2::Util::HashBase qw/results listeners proc result type job/;
use Test2::Harness::TAPUtil qw/parse_tap_line/;

use Test2::Harness::Result qw{
    EVENTS
    OUT_LINES
    ERR_LINES
    SUBTESTS
    PARSE_ERRORS
};

sub EVENTSTREAM() { 1 }
sub TAP()         { 2 }

sub init {
    my $self = shift;

    croak "'proc' is a required attribute"
        unless $self->{+PROC};

    croak "'job' is a required attribute"
        unless $self->{+JOB};

    $self->{+RESULTS} = [
        Test2::Harness::Result->new(
            file => $self->{+PROC}->file,
            job  => $self->{+JOB},
        ),
    ];

    my $listeners = $self->{+LISTENERS} ||= [];

    $_->($self->{+JOB} => 'START', $self->{+PROC}->file) for @$listeners;
}

sub is_done {
    my $self = shift;
    return $self->{+RESULT};
}

sub step {
    my $self = shift;
    return -1 if $self->{+RESULT};

    return -1 if $self->_check_for_exit;

    return 1 if $self->parse_stdout;
    return 1 if $self->parse_stderr;

    return 0;
}

sub _check_for_exit {
    my $self = shift;
    my $proc = $self->{+PROC};
    return unless $proc->is_done;

    my $found = 1;
    while ($found) {
        $found = 0;
        $found += $self->parse_stdout;
        $found += $self->parse_stderr;
    }

    $self->pop_results(-1 => $proc->exit);
}

sub push_results {
    my $self = shift;
    my ($nesting) = @_;

    # TODO: Handle STDERR stuff

    push @{$self->{+RESULTS}} => Test2::Harness::Result->new(
        job    => $self->{+JOB},
        file   => $self->{+PROC}->file,
        nested => $nesting,
    );
}

sub pop_results {
    my $self = shift;
    my ($stop, $exit) = @_;

    my $results = $self->{+RESULTS};

    # TODO: Handle STDERR stuff

    while (@$results) {
        my $r = pop @$results;
        my $nest = $r->nested;
        $r->stop($exit);

        my ($into) = reverse @$results;

        if ($into) {
            # Something in between
            $into = $self->push_results($stop) if $into->nested < $stop;

            $self->notify(SUBTESTS() => $r);
            return $r if $into->nested == $stop;
        }
        else {
            $self->{+RESULT} = $r;
            $self->notify(SUBTESTS() => $r);
            return $r;
        }
    }
}

sub get_type {
    my $self = shift;
    my ($io, $line) = @_;

    return $self->{+TYPE} if $self->{+TYPE};

    return 0 if $io ne 'STDOUT';

    return $self->{+TYPE} = EVENTSTREAM()
        if $line =~ m/T2_EVENT:\s/;

    # Intentionally not setting a type for comments.
    return $self->{+TYPE} = TAP()
        if $line =~ m/^\s*(ok\b|not ok\b|Bail out!\b|1\.\.\d+\b|TAP version )/;

    return 0;
}

sub parse_stderr {
    my $self = shift;
    # TODO: PEEK line, skip if we are not at the right nesting, but only for
    # events!

    my $line = $self->proc->get_err_line or return 0;

    $self->_parse_line(STDERR => $line, ERR_LINES());

    return 1;
}

sub parse_stdout {
    my $self = shift;
    my $line = $self->proc->get_out_line or return 0;

    my $e = $self->_parse_line(STDOUT => $line, OUT_LINES());
    # TODO Catch up of failure diag if causes_fail

    return 1;
}

sub _parse_line {
    my $self = shift;
    my ($io, $line, $dest) = @_;

    chomp($line);
    my $type = $self->get_type($io => $line);

    my ($e, @errors);
    if ($type == EVENTSTREAM && $io eq 'STDOUT') {
        ($e, @errors) = Test2::Harness::Event->from_line($line);
    }
    elsif($type == TAP) {
        ($e, @errors) = parse_tap_line($io => $line);
    }

    # STDERR does not push/pop subtests
    if ($e && $io eq 'STDOUT') {
        my $new_nest = $e->nested || 0;
        my $old_nest = $self->{+RESULTS}->[-1]->nested || 0;

        if ($new_nest < $old_nest) {
            $self->pop_results($new_nest, 0);
        }
        elsif ($new_nest > $old_nest) {
            $self->push_results($new_nest);
        }

        die "INTERNAL ERROR: Failed to equalize nesting!"
            unless $new_nest == $self->{+RESULTS}->[-1]->nested;
    }

    unless ($e || @errors) {
        $self->notify($dest => $line);
        return;
    }

    # A parsing error counts as a failure if no event could be obtained
    $self->{+RESULTS}->[-1]->bump_failed(scalar @errors)
        if @errors && !$e;

    $self->notify(EVENTS() => $e) if $e;
    $self->notify(PARSE_ERRORS() => @errors) if @errors;

    return $e;
}

sub notify {
    my $self = shift;

    my ($result) = reverse @{$self->{+RESULTS}};
    $result->add(@_) if $result;

    $_->($self->{+JOB} => @_) for @{$self->{+LISTENERS}};
}

1;
