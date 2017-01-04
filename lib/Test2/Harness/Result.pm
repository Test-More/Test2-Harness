package Test2::Harness::Result;
use strict;
use warnings;

our $VERSION = '0.000014';

use Carp qw/croak/;
use Time::HiRes qw/time/;

use Test2::Util::HashBase qw{
    file name job

    total      failed
    start_time stop_time
    exit

    plans

    events
};

sub init {
    my $self = shift;

    croak "'file' is a required attribute"
        unless $self->{+FILE};

    croak "'job' is a required attribute"
        unless $self->{+JOB};

    croak "'name' is a required attribute"
        unless $self->{+NAME};

    # Overall stuff
    $self->{+START_TIME} ||= time;
    $self->{+TOTAL}      ||= 0;
    $self->{+FAILED}     ||= 0;

    # Plan related
    $self->{+PLANS} ||= [];

    $self->{+EVENTS} ||= [];
}

sub stop {
    my $self = shift;
    my ($exit) = @_;

    $self->{+STOP_TIME} = time;
    $self->{+EXIT}      = $exit;
}

sub passed {
    my $self = shift;
    return unless defined $self->{+STOP_TIME};

    return 0 if $self->{+EXIT};
    return 0 if $self->{+FAILED};
    return 1;
}

sub ran_tests {
    my $self = shift;

    my $plans = $self->{+PLANS};
    return 0 if $plans && @$plans && $plans->[0]->directive eq 'SKIP';
    return 0 unless grep { $_->increments_count } @{$self->{+EVENTS}};
    return 1;
}

sub bump_failed { $_[0]->{+FAILED} += $_[1] || 1 }

sub add_events {
    my $self = shift;
    $self->add_event($_) for @_;
}

sub add_event {
    my $self = shift;
    my ($e) = @_;

    push @{$self->{+EVENTS}} => $e;

    return unless ($e->nested || 0) <= 0;

    $self->{+TOTAL}++ if $e->increments_count;
    if ($e->isa('Test2::Event::Plan')) {
        my @set = $e->sets_plan;
        push @{$self->{+PLANS}}, $e unless $set[1] && $set[1] eq 'NO PLAN';
    }

    $self->{+FAILED}++ if $e->causes_fail || $e->terminate;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Result - Representation of a complete test

=head1 DESCRIPTION

This object is used to represent a complete test.

=head1 METHODS

=over 4

=item $filename = $r->file

Get the filename of the running test.

=item $name = $r->name

Get the name of the file.

=item $job_id = $r->job

Get the job id.

=item $int = $r->total

Number of events that have incremented the test count.

=item $int = $r->failed

Number of failures/errors seen.

=item $ts = $r->start_time

Timestamp from object creation.

=item $ts = $r->stop_time

Timestamp from when the test stopped.

=item $exit = $r->exit

If the test is complete this will have the exit code. This is undefined while
the test is running.

=item $plans_ref = $r->plans

Get a list of all plans encountered. If this has more than 1 plan an error will
be rendered and the test will be considered a failure.

=item $events_ref = $r->planning

Get a list of all events that are involved in planning. This includes all plan
events, and all events that increment the test count.

=item $errors_ref = $r->plan_errors

Get a list of plan errors (IE Plan and test count do not match).

=item $events_ref = $r->events

Get a list of all the events that were seen.

=item $r->stop($exit)

End the test, and provide the exit code.

=item $bool = $r->passed

Check if the result is a pass.

=item $bool = $r->ran_tests

Check if the result is for a process that ran any tests at all.

=item $r->bump_failed

Add to the number of failures.

=item $r->add_events(@events)

=item $r->add_event($event)

Used to add and process one or more events.

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

Copyright 2016 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
