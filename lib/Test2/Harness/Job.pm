package Test2::Harness::Job;
use strict;
use warnings;

our $VERSION = '0.000009';

use Carp qw/croak/;
use Time::HiRes qw/time/;
use Test2::Util::HashBase qw{
    id file listeners parser proc result _done subtests _timeout
    _timeout_notified
};

use Test2::Harness::Result;
use Test2::Harness::Fact;

sub init {
    my $self = shift;

    croak "job 'id' is required"
        unless $self->{+ID};

    croak "job 'file' is required"
        unless $self->{+FILE};

    $self->{+LISTENERS} ||= [];

    $self->{+SUBTESTS} = {};

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

    my ($proc, @facts) = $runner->start(
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

    my $start = Test2::Harness::Fact->new(start => $self->{+FILE});
    $self->notify($start, @facts);
}

sub notify {
    my $self = shift;
    my (@facts) = @_;

    return unless @facts;

    for my $f (@facts) {
        $f = $self->end_subtest($f) if $f->is_subtest;
        my $r = $self->subtest_result($f);

        $r->add_facts($f);
        $_->($self->{+ID}, $f) for @{$self->{+LISTENERS}};
    }
}

sub subtest_result {
    my $self = shift;
    my ($f) = @_;

    my $st = $f->in_subtest;
    my $r = $st
        ? $self->{+SUBTESTS}->{$st} ||= Test2::Harness::Result->new(job => $self->{+ID}, file => $self->{+FILE}, name => $st)
        : $self->{+RESULT};

    return $r;
}

sub end_subtest {
    my $self = shift;
    my ($f) = @_;

    my $st = $f->is_subtest or return $f;

    my $r = delete $self->{+SUBTESTS}->{$st} || Test2::Harness::Result->new(
        file => $self->{+FILE},
        name => "Unknown subtest",
        job  => $self->{+ID},
    );

    $r->set_name($f->summary);
    $r->stop(0);
    $r->add_fact(
        Test2::Harness::Fact->new(
            causes_fail => 1,
            diagnostics => 1,
            parse_error => "Subtest event reports failure",
        ),
    ) if $f->causes_fail && $r->passed;

    return Test2::Harness::Fact->from_result(
        $r,

        number           => $f->number           || undef,
        name             => $f->summary          || 'Unnamed subtest',
        in_subtest       => $f->in_subtest       || undef,
        is_subtest       => $f->is_subtest       || undef,
        increments_count => $f->increments_count || 0,
    );
}

sub step {
    my $self = shift;
    my @facts = $self->{+PARSER}->step;
    $self->notify(@facts);
    return @facts ? 1 : 0;
}

sub timeout {
    my $self = shift;

    # No timeout if the process exits badly
    return 0 if $self->{+PROC}->exit;

    my $r = $self->{+RESULT};
    my $plans = $r->plans;

    if ($plans && @$plans) {
        my ($plan) = @$plans;
        my ($max) = @{$plan->sets_plan};

        return 0 unless $max;
        return 0 if $max == $r->total;
    }

    # 60 seconds if all else fails.
    return 60;
}

sub is_done {
    my $self = shift;

    return 1 if $self->{+_DONE};

    my $proc = $self->{+PROC};
    return 0 unless $proc->is_done;

    if($self->step) {
        delete $self->{+_TIMEOUT} or return 0;

        $self->notify(
            Test2::Harness::Fact->new(
                summary     => "Event received, timeout reset.\n",
                parse_error => 1,
                diagnostics => 1,
            ),
        ) if $self->{+_TIMEOUT_NOTIFIED};

        return 0;
    }

    if (my $timeout = $self->timeout) {
        unless ($self->{+_TIMEOUT}) {
            $self->{+_TIMEOUT} = time;

            $self->notify(
                Test2::Harness::Fact->new(
                    summary     => "Process has exited but the event stream does not appear complete. Waiting $timeout seconds...\n",
                    parse_error => 1,
                    diagnostics => 1,
                ),
            ) if $timeout >= 1 && !$self->{+_TIMEOUT_NOTIFIED}++;

            return 0;
        }

        return 0 if $timeout > (time - $self->{+_TIMEOUT});
    }

    $self->{+_DONE} = 1;

    $self->{+RESULT}->stop($proc->exit);

    $self->notify(Test2::Harness::Fact->from_result($self->{+RESULT}));

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

The job object is also responsible for assembling L<Test2::Harness::Result>
objects based on the L<Test2::Harness::Fact> objects that pass through it. This
includes subtest results.

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

=item $j->notify(@facts)

This sends the facts to all listeners, it also records them for the final
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

Run an iteration. This will return true if any facts were generated, false
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
