package Test2::Harness::Watcher;
use strict;
use warnings;

our $VERSION = '0.001079';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use List::Util qw/first max/;

use Test2::Harness::Util::UUID qw/gen_uuid/;

use Test2::Harness::Util qw/hub_truth parse_exit/;

use Test2::Harness::Util::HashBase qw{
    -job
    -live

    -_complete
    -killed

    -events

    -assertion_count
    -exit
    -plan
    -_errors
    -_failures
    -_sub_failures
    -_plans
    -_info
    -_sub_info
    -nested
    -subtests
    -numbers

    -last_event
};

sub init {
    my $self = shift;

    croak "'job' is a required attribute"
        unless $self->{+JOB};

    $self->{+_FAILURES}       = 0;
    $self->{+_ERRORS}         = 0;
    $self->{+ASSERTION_COUNT} = 0;

    $self->{+NUMBERS} = {};

    $self->{+NESTED} = 0 unless defined $self->{+NESTED};
}

sub clear_events { delete $_[0]->{+EVENTS} }

sub has_exit { defined $_[0]->{+EXIT} }
sub has_plan { defined $_[0]->{+PLAN} }

sub file {
    my $self = shift;
    return $self->{+JOB}->file;
}

sub process {
    my $self = shift;
    my ($event) = @_;

    my @e = $self->_process($event);

    push @{$self->{+EVENTS}} => ($event, @e);

    return @e;
}

sub _process {
    my $self = shift;
    my ($event) = @_;

    $self->{+LAST_EVENT} = time;

    my $f = $event->{facet_data};

    my $hf = hub_truth($f);

    return if $hf->{buffered};

    my $nested = $hf->{nested} || 0;
    my $is_ours = $nested == $self->{+NESTED};

    return unless $is_ours || $f->{from_tap};

    # Add parent if we start a buffered subtest
    if ($f->{harness} && $f->{harness}->{subtest_start}) {
        my $st = $self->{+SUBTESTS}->{$nested + 1} ||= {};
        $st->{event} = $event;
        $f->{harness_watcher}->{no_render} = 1;
        return;
    }

    my @out;

    # Not actually a subtest end, someone printed to STDOUT
    if ($f->{from_tap} && $f->{harness}->{subtest_end} && !($self->{+SUBTESTS} && keys %{$self->{+SUBTESTS}})) {
        # Alter $f so that this incorrect event is not send to the renderer.
        $f->{harness_watcher}->{no_render} = 1;

        # Make a new $f and $event for the rest of the processing.
        $f = {
            %{$f},
            harness_watcher => {added_by_watcher => 1},
            parent          => undef,
            trace           => undef,
            harness         => {
                %{$f->{harness} || {}},
                subtest_end => undef,
            },
            info => [
                @{$f->{info} || []},
                {
                    details      => $f->{from_tap}->{details},
                    tag          => $f->{from_tap}->{source} || 'STDOUT',
                    from_harness => 1,
                }
            ],
        };

        $event = Test2::Harness::Event->new(stamp => time, facet_data => $f);

        push @out => $event;
    }

    # Close any deeper subtests
    if (my $sts = $self->{+SUBTESTS}) {
        my @close = sort { $b <=> $a } grep { $_ > $nested } keys %$sts;

        for my $n (@close) {
            my $st = delete $sts->{$n};
            my $se = $st->{event} || $event;

            my $fd = $se->{facet_data};
            delete $fd->{harness_watcher}->{no_render};
            $fd->{parent}->{hid} ||= $n;
            $fd->{parent}->{children} ||= $st->{children};
            $fd->{harness}->{closed_by}     = $event;
            $fd->{harness}->{closed_by_eid} = $event->{event_id};

            my $pn = $n - 1;

            if ($st->{event}) {
                if ($pn > $self->{+NESTED}) {
                    push @{$sts->{$pn}->{children}} => $fd;
                }
                elsif ($pn == $self->{+NESTED}) {
                    $self->subtest_process($fd, $se);
                    push @out => $se;
                }
            }
            else {
                push @out => $se if $self->{+NESTED} && $pn == $self->{+NESTED};
            }
        }
    }

    unless ($is_ours) {
        my $st = $self->{+SUBTESTS}->{$nested} ||= {};
        my $fd = {%$f};
        push @{$st->{children}} => $fd;
        return @out;
    }

    $self->subtest_process($f, $event);
    return @out;
}

sub subtest_process {
    my $self = shift;
    my ($f, $event) = @_;

    my $closer = delete $f->{harness}->{closed_by};
    $event ||= Test2::Harness::Event->new(facet_data => $f);

    $self->{+NUMBERS}->{$f->{assert}->{number}}++
        if $f->{assert} && $f->{assert}->{number};

    if ($f->{parent} && $f->{assert}) {
        my $subwatcher = blessed($self)->new(nested => $self->{+NESTED} + 1, job => $self->{+JOB});

        my $id = 1;
        for my $sf (@{$f->{parent}->{children}}) {
            $sf->{harness}->{job_id}   ||= $f->{harness}->{job_id};
            $sf->{harness}->{run_id}   ||= $f->{harness}->{run_id};
            $sf->{harness}->{event_id} ||= $sf->{about}->{uuid} ||= gen_uuid();
            $subwatcher->subtest_process($sf);
        }

        my @errors = $subwatcher->subtest_fail_error_facet_list();

        if ($f->{harness}->{subtest_start}) {
            push @{$f->{errors}} => {tag => 'REASON', fail => 1, from_harness => 1, details => "Buffered subtest ended abruptly (missing closing brace event)"}
                unless $closer && $closer->{facet_data}->{harness}->{subtest_end};
        }

        if (@errors) {
            $self->{+_SUB_FAILURES}++;
            push @{$f->{errors}} => @errors;
        }
        else {
            my $fail = $f->{assert} && !$f->{assert}->{pass} && !($f->{amnesty} && @{$f->{amnesty}});
            $fail ||= $f->{control} && ($f->{control}->{halt} || $f->{control}->{terminate});
            $fail ||= $f->{errors} && first { $_->{fail} } @{$f->{errors}};

            $self->{+_SUB_FAILURES}++ if $fail;
        }
    }

    $self->{+ASSERTION_COUNT}++ if $f->{assert};

    if ($f->{assert} && !$f->{assert}->{pass} && !($f->{amnesty} && @{$f->{amnesty}})) {
        $self->{+_FAILURES}++;
    }

    if ($f->{control} || $f->{errors}) {
        my $err ||= $f->{control} && ($f->{control}->{halt} || $f->{control}->{terminate});
        $err ||= $f->{errors} && first { $_->{fail} } @{$f->{errors}};
        $self->{+_ERRORS}++ if $err;
    }

    if ($f->{plan} && !$f->{plan}->{none}) {
        $self->{+_PLANS}++;
        $self->{+PLAN} = $f->{plan};
    }

    if ($f->{harness_job_exit} && defined $f->{harness_job_exit}->{exit}) {
        $self->{+EXIT} = $f->{harness_job_exit}->{exit};
    }

    return;
}

sub fail {
    my $self = shift;
    return !!$self->fail_error_facet_list;
}

sub subtest_fail_error_facet_list {
    my $self = shift;

    return @{$self->{+_SUB_INFO}} if $self->{+_SUB_INFO};

    my @out;

    my $plan = $self->{+PLAN} ? $self->{+PLAN}->{count} : undef;
    my $count = $self->{+ASSERTION_COUNT};

    my $numbers = $self->{+NUMBERS};
    my $max     = max(keys %$numbers);
    if ($max) {
        for my $i (1 .. $max) {
            if (!$numbers->{$i}) {
                push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Assertion number $i was never seen"};
            }
            elsif ($numbers->{$i} > 1) {
                push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Assertion number $i was seen more than once"};
            }
        }
    }

    if (!$self->{+_PLANS}) {
        if ($count) {
            push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "No plan was declared"};
        }
        else {
            push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "No plan was declared, and no assertions were made."};
        }
    }
    elsif ($self->{+_PLANS} > 1) {
        push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Too many plans were declared (Count: $self->{+_PLANS})"};
    }

    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Planned for $plan assertions, but saw $self->{+ASSERTION_COUNT}"}
        if $plan && $count != $plan;

    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Subtest failures were encountered (Count: $self->{+_SUB_FAILURES})"}
        if $self->{+_SUB_FAILURES};

    return @out;
}

sub fail_error_facet_list {
    my $self = shift;

    return @{$self->{+_INFO}} if $self->{+_INFO};

    my @out;

    my $incomplete_subtests = values %{$self->{+SUBTESTS}};
    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "One or more incomplete subtests (Count: $incomplete_subtests)"}
        if $incomplete_subtests;

    if (my $wstat = $self->{+EXIT}) {
        if ($wstat == -1) {
            push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "The harness could not get the exit code! (Code: $wstat)"};
        }
        else {
            my $e = parse_exit($wstat);
            if ($e->{err}) {
                push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Test script returned error (Err: $e->{err})"};
            }
            if ($e->{sig}) {
                push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Test script returned error (Signal: $e->{sig})"};
            }
        }
    }

    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Errors were encountered (Count: $self->{+_ERRORS})"}
        if $self->{+_ERRORS};

    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Assertion failures were encountered (Count: $self->{+_FAILURES})"}
        if $self->{+_FAILURES};

    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Test file was killed"}
        if $self->{+KILLED};

    push @out => $self->subtest_fail_error_facet_list();

    return @out;
}

sub pass {
    my $self = shift;

    return !$self->fail;
}

# We do not ever want the watcher to be stored
sub TO_JSON { undef }

sub kill {
    my $self = shift;

    $self->{+KILLED} = time;

    return 0 unless $self->{+LIVE};
    return 1 if defined $self->{+EXIT};

    my $pid = $self->{+JOB}->pid;

    return kill('TERM', $pid) if $pid;
    return 0;
}

sub set_complete {
    my $self = shift;
    ($self->{+_COMPLETE}) = @_;
}

sub complete {
    my $self = shift;

    return 1 unless $self->{+LIVE};
    return 1 if $self->{+_COMPLETE};

    my $exit  = $self->{+EXIT};
    my $plan  = $self->{+PLAN} ? $self->{+PLAN}->{count} : undef;
    my $count = $self->{+ASSERTION_COUNT};

    my $has_exit = defined($exit) ? 1 : 0;
    my $has_plan = defined($plan) ? 1 : 0;

    return $self->{+_COMPLETE} = 1 if $self->{+KILLED} && $has_exit;

    # Script exited badly
    return $self->{+_COMPLETE} = 1 if $exit;

    # Script exited with no plan or assertions
    return $self->{+_COMPLETE} = 1 if $has_exit && !$has_plan && !$count;

    # Script exited with completed plan
    return $self->{+_COMPLETE} = 1 if $has_exit && $has_plan && $plan <= $count;

    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Watcher - Class to monitor events for a single job and pass
judgement on the result.

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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
