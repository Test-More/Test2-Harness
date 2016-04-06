package Test2::Harness::Parser::EventStream;
use strict;
use warnings;

use Test2::Harness::Result;
use Test2::Harness::Fact;

use base 'Test2::Harness::Parser';
use Test2::Util::HashBase qw/results/;

sub morph {
    my $self = shift;

    my $file = $self->{+PROC}->file;

    $self->{+RESULTS} = {
        $file => Test2::Harness::Result->new(
            file => $file,
            name => $file,
            job  => $self->{+JOB},
        ),
    };
}

sub finish {
    my $self = shift;
    my ($exit) = @_;

    my $file = $self->{+PROC}->file;

    my $r = delete $self->{+RESULTS}->{$file};

    # Close any remaining subtests, badly
    $self->_end_subtest($_) for keys %{$self->{+RESULTS}};

    $r->stop($exit);

    $self->{+RESULT} = $r;
}

sub parse_stderr {
    my $self = shift;

    my $line = $self->proc->get_err_line or return 0;

    chomp($line);

    my $fact = Test2::Harness::Fact->new(
        output             => $line,
        parsed_from_handle => 'STDERR',
        parsed_from_string => $line,
        diagnostics        => 1,
    );

    $self->notify($fact);

    return 1;
}

sub parse_line {
    my $self = shift;
    my ($io, $line) = @_;

    chomp($line);

    my (@facts) = Test2::Harness::Fact->from_string($line, parsed_from_handle => $io);

    return Test2::Harness::Fact->new(
        output             => $line,
        parsed_from_handle => $io,
        parsed_from_string => $line,
        diagnostics        => 0,
    ) unless @facts;

    my $file = $self->{+PROC}->file;
    my $results = $self->{+RESULTS};

    # Anything after the first is a parsing error
    # No non-parse-error, must be a problem.
    $results->{$file}->bump_failed(1)
        if $facts[0]->parse_error;

    for my $f (@facts) {
        $f = $self->end_subtest($f->is_subtest, $f) if $f->is_subtest;

        my $st = $f->in_subtest || $file;
        my $r = $results->{$st} ||= Test2::Harness::Result->new(
            file   => $file,
            job    => $self->{+JOB},
            name   => "UNKNOWN SUBTEST",
            nested => $f->nested,
        );
        $r->add_fact($f);
    }

    return @facts;
}

sub end_subtest {
    my $self = shift;
    my ($st, $f) = @_;

    my $results = $self->{+RESULTS};

    # If we are not tracking the subtest we assume the produce hid the events
    # from us. Just give the event back
    my $r = delete $results->{$st} or return $f;

    unless ($f) {
        $r->add_fact(
            Test2::Harness::Fact->new(
                causes_fail => 1,
                diagnostics => 1,
                parse_error => "Subtest was tracked, but we never saw a Subtest event!",
            ),
        );
        $r->stop(0);
        return Test2::Harness::Fact->from_result($r);
    }

    $r->set_name($f->summary);
    $r->add_fact(
        Test2::Harness::Fact->new(
            causes_fail => 1,
            diagnostics => 1,
            summary     => "Subtest event reports failure",
        ),
    ) if $f->causes_fail;
    $r->stop(0);

    return Test2::Harness::Fact->from_result(
        $r,

        name             => $f->summary          || 'Unnamed subtest',
        in_subtest       => $f->in_subtest       || undef,
        is_subtest       => $f->is_subtest       || undef,
        increments_count => $f->increments_count || 0,
    );
}

1;
