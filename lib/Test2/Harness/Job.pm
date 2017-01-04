package Test2::Harness::Job;
use strict;
use warnings;

our $VERSION = '0.000014';

use Carp qw/croak/;
use Time::HiRes qw/time/;
use Test2::Util::HashBase qw{
    id file listeners parser proc result
    event_timeout
    _done _timeout _timeout_notified
};

use Test2::Event::ParseError;
use Test2::Event::ProcessStart;
use Test2::Event::ProcessFinish;
use Test2::Event::Subtest;
use Test2::Event::TimeoutReset;
use Test2::Event::UnexpectedProcessExit;
use Test2::Harness::Result;

sub init {
    my $self = shift;

    croak "job 'id' is required"
        unless $self->{+ID};

    croak "job 'file' is required"
        unless $self->{+FILE};

    $self->{+LISTENERS} ||= [];

    $self->{+RESULT} ||= Test2::Harness::Result->new(
        file => $self->{+FILE},
        name => $self->{+FILE},
        job  => $self->{+ID},
    );
}

sub start {
    my $self = shift;
    my %params = @_;

    my $id = $self->{+ID};
    my ($runner, $start_args, $parser_class) = @params{qw/runner start_args parser_class/};

    my ($proc, @events) = $runner->start(
        $self->{+FILE},
        %$start_args,
        job => $id,
    );

    die "Failed to get a proc object" unless $proc;

    my $parser = $parser_class->new(
        job  => $id,
        proc => $proc,
    );

    die "Failed to get a parser object" unless $parser;

    $self->{+PROC}   = $proc;
    $self->{+PARSER} = $parser;

    my $start = Test2::Event::ProcessStart->new(file => $self->{+FILE});
    $self->notify($start, @events);
}

sub notify {
    my $self = shift;
    my (@events) = @_;

    return unless @events;

    for my $e (@events) {
        $_->($self, $e) for @{$self->{+LISTENERS}};
    }
    # The ProcessFinish event contains a reference to the result, so if we add
    # that event to the result we end up with a circular ref.
    $self->{+RESULT}->add_events(grep { !$_->isa('Test2::Event::ProcessFinish') } @events);
}

sub step {
    my $self   = shift;
    my @events = $self->{+PARSER}->step;
    $self->notify(@events);
    if (@events && $self->{+_TIMEOUT}) {
        delete $self->{+_TIMEOUT};
        $self->notify(Test2::Event::TimeoutReset->new(file => $self->{+FILE}))
            if $self->{+_TIMEOUT_NOTIFIED};
    }
    return @events ? 1 : 0;
}

sub timeout {
    my $self = shift;

    # No timeout if the process exits badly
    return 0 if $self->{+PROC}->exit;

    my $r = $self->{+RESULT};
    my $plans = $r->plans;

    if ($plans && @$plans) {
        my $plan = $plans->[0];
        my $max  = ($plan->sets_plan)[0];

        return 0 unless $max;
        return 0 if $max == $r->total;
    }

    # 60 seconds if all else fails.
    return $self->{+EVENT_TIMEOUT} || 60;
}

sub is_done {
    my $self = shift;

    return 1 if $self->{+_DONE};

    return $self->_incomplete_timeout
        if $self->proc->is_done;

    return $self->_event_timeout;
}

sub _event_timeout {
    my $self = shift;

    my $timeout = $self->{+EVENT_TIMEOUT}
        or return 0;

    return 0 if $self->step;
    $self->{+_TIMEOUT} ||= time;

    return 0 if $timeout > (time - $self->{+_TIMEOUT});

    # We timed out!
    $self->notify(
        Test2::Event::UnexpectedProcessExit->new(
            error => "Process timed out after $timeout seconds with no events...",
            file  => $self->{+FILE},
        ),
    );

    $self->{+PROC}->force_kill;

    return $self->finish;
}

sub _incomplete_timeout {
    my $self = shift;

    # If the process finished but forked a subprocess that is still producing
    # output, then we might see something when we call ->step. This is fairly
    # pathological, but we try to handle it.
    return 0 if $self->step;

    my $proc = $self->{+PROC};

    if (my $timeout = $self->timeout) {
        unless ($self->{+_TIMEOUT}) {
            $self->{+_TIMEOUT} = time;

            $self->notify(
                Test2::Event::UnexpectedProcessExit->new(
                    error => "Process has exited but the event stream does not appear complete. Waiting $timeout seconds...",
                    file  => $self->{+FILE},
                ),
            ) if $timeout >= 1 && !$self->{+_TIMEOUT_NOTIFIED}++;

            return 0;
        }

        return 0 if $timeout > (time - $self->{+_TIMEOUT});
    }

    return $self->finish;
}

sub finish {
    my $self = shift;

    $self->{+_DONE} = 1;

    my $proc = $self->{+PROC};
    $self->{+RESULT}->stop($proc->exit);

    $self->notify(Test2::Event::ProcessFinish->new(file => $proc->file, result => $self->{+RESULT}));

    return 1;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Job - Control over a running test file.

=head1 DESCRIPTION

The job object is an abstract representation of a running test. It is
responsible for starting the test using an L<Test2::Harness::Runner>, managing
the process with an L<Test2::Harness::Proc> object, and delegating work to an
L<Test2::Harness::Parser>. The L<Test2::Harness> object interacts directly with
the Job object.

The job object is also responsible for sending L<Test2::Event::ProcessStart>
and L<Test2::Event::ProcessFinish> events, as well as a few other events in
the case of errors.

=head1 PUBLIC METHODS

B<Note> not all private methods have _ prefixes yet. If the method is not on
this list assume it is private. Some additional methods may be documented
later.

=over 4

=item $file = $j->file()

Get the test filename.

=item $id = $j->id()

Get the job's ID as used/assigned by the harness.

=item $bool = $j->is_done()

Check if the job is done yet.

=item $j->notify(@events)

This sends the events to all listeners, it also records them for the final
result object and all subtest result objects.

=item $parser = $j->parser()

Get the L<Test2::Harness::Parser> instance.

=item $proc = $j->proc()

Get the L<Test2::Harness::Proc> instance.

=item $j->start(%params)

Start the job.

    $j->start(
        runner       => $runner, # The L<Test2::Harness::Runner> instance
        start_args   => \@args,  # Args passed into $runner->start
        parser_class => $parser, # Parser class to use.
    );

=item $bool = $j->step()

Run an iteration. This will return true if any events were generated, false
otherwise. This is called in an event loop by the L<Test2::Harness> object.

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
