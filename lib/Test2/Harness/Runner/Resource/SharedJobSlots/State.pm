package Test2::Harness::Runner::Resource::SharedJobSlots::State;
use strict;
use warnings;

our $VERSION = '1.000152';

use Time::HiRes qw/time/;
use List::Util qw/min sum0 max/;
use Carp qw/croak/;

use parent 'Test2::Harness::IPC::SharedState';
use Test2::Harness::Util::HashBase qw{
    <max_slots
    <max_slots_per_job
    <max_slots_per_run
    <min_slots_per_run
    <default_slots_per_job
    <default_slots_per_run

    <my_max_slots
    <my_max_slots_per_job

    <algorithm

    <ready_assignments
};

use constant RUNNERS => 'runners';
use constant RUNNER_ID => 'access_id';

sub init {
    my $self = shift;

    $self->SUPER::init();

    croak "'max_slots' is a required attribute"         unless $self->{+MAX_SLOTS};
    croak "'max_slots_per_job' is a required attribute" unless $self->{+MAX_SLOTS_PER_JOB};
    croak "'max_slots_per_run' is a required attribute" unless $self->{+MAX_SLOTS_PER_RUN};

    $self->{+MY_MAX_SLOTS}         //= $self->{+MAX_SLOTS};
    $self->{+MY_MAX_SLOTS_PER_JOB} //= $self->{+MAX_SLOTS_PER_JOB};

    $self->{+MIN_SLOTS_PER_RUN} //= 0;

    $self->{+ACCESS_META}->{name} //= $self->{+ACCESS_ID};

    $self->{+ALGORITHM} //= '_redistribute_fair';
}

sub init_state {
    my $self = shift;
    my $state = $self->SUPER::init_state();
    $state->{+RUNNERS} = {};
    return $state;
}

sub _clear_old_registrations {
    my $self = shift;
    my ($state) = @_;

    my $removed = $self->SUPER::_clear_old_registrations(@_);

    my $runners = $state->{+RUNNERS};
    delete $runners->{$_} for @$removed;

    return $removed;
}

sub allocate_slots {
    my $self = shift;
    my (%params) = @_;

    my $con    = $params{con}    or croak "'con' is required";
    my $job_id = $params{job_id} or croak "'job_id' is required";

    return $self->transaction(rw => '_allocate_slots', con => $con, job_id => $job_id);
}

sub assign_slots {
    my $self = shift;
    my (%params) = @_;

    my $job = $params{job} or croak "'job' is required";

    return $self->transaction(rw => '_assign_slots', job => $job);
}

sub release_slots {
    my $self = shift;
    my (%params) = @_;

    my $job_id = $params{job_id} or croak "'job_id' is required";

    return $self->transaction(rw => '_release_slots', job_id => $job_id);
}

sub _get_runner_entry {
    my $self = shift;
    my ($state, $runner_id) = @_;

    $runner_id //= $self->{+RUNNER_ID};

    return $state->{+RUNNERS}->{$runner_id} //= {
        runner_id => $runner_id,
        added     => time,

        todo      => 0,
        allocated => 0,
        allotment => 0,
        assigned  => {},

        max_slots         => $self->{+MY_MAX_SLOTS},
        max_slots_per_job => $self->{+MY_MAX_SLOTS_PER_JOB},
    };
}

sub _allocate_slots {
    my $self = shift;
    my ($state, %params) = @_;

    my $entry = $self->_get_runner_entry($state);
    delete $entry->{_calc_cache};

    my $job_id = $params{job_id};
    my $con    = $params{con};
    my ($min, $max) = @$con;
    $self->_runner_todo($entry, $job_id => $max);

    my $allocated = $entry->{allocated} //= 0;

    # We have what we need already allocated
    return $entry->{allocated} = $max
        if $max <= $allocated;

    return $entry->{allocated}
        if $entry->{allocated} >= $min;

    # Our allocation, if any, is not big enough, free it so we do not have a
    # deadlock with all runner holding an insufficient allocation.
    $allocated = $entry->{allocated} = 0;

    my $calcs = $self->_runner_calcs($entry);

    for (0 .. 1) {
        $self->_redistribute($state) if $_; # Only run on second loop

        # Cannot do anything if we have no allotment or no available slots.
        # This will go to the next loop for a redistribution, or end the loop.
        my $allotment = $entry->{allotment}             or next;
        my $available = $allotment - $calcs->{assigned} or next;

        # If we get here we have an allotment (not 0) but it does not mean the
        # minimum, so we have to skip the test.
        return -1 if $allotment < $min;

        next unless $available >= $min;

        return $entry->{allocated} = min($available, $max);
    }

    return 0;
}

sub _assign_slots {
    my $self = shift;
    my ($state, %params) = @_;

    my $entry = $self->_get_runner_entry($state);
    delete $entry->{_calc_cache};

    my $job       = $params{job};
    my $job_id    = $job->{job_id};
    my $allocated = $entry->{allocated};

    $self->_runner_todo($entry, $job_id => -1);

    $job->{count} = $allocated;
    $job->{started} = time;

    $entry->{allocated} = 0;

    $entry->{assigned}->{$job->{job_id}} = $job;

    return $job;
}

sub _release_slots {
    my $self = shift;
    my ($state, %params) = @_;

    my $entry = $self->_get_runner_entry($state);

    my $job_id = $params{job_id};

    delete $entry->{assigned}->{$job_id};
    delete $entry->{_calc_cache};

    $self->_runner_todo($entry, $job_id => -1);

    # Reduce our allotment if it makes sense to do so.
    my $calcs = $self->_runner_calcs($entry);
    $entry->{allotment} = $calcs->{total} if $entry->{allotment} > $calcs->{total};
}

sub _runner_todo {
    my $sef = shift;
    my ($entry, $job_id, $count) = @_;

    my $jobs = $entry->{jobs} //= {};

    if ($count) {
        if ($count < 0) {
            $count = delete $jobs->{$job_id};
        }
        else {
            $jobs->{$job_id} = $count;
        }
    }
    elsif ($job_id) {
        $count = $jobs->{$job_id};
    }

    $entry->{todo} = sum0(values %$jobs);

    return $count;
}

sub _runner_calcs {
    my $self = shift;
    my ($runner) = @_;

    return $runner->{_calc_cache} if $runner->{_calc_cache};

    my $max      = min(grep {$_} $self->{+MAX_SLOTS_PER_RUN}, $runner->{max_slots});
    my $assigned = sum0(map { $_->{count} } values %{$runner->{assigned} //= {}});
    my $active   = $runner->{allocated} + $assigned;
    my $total    = $runner->{todo} + $active;
    my $wants    = ($total >= $max) ? max($max, $active) : max($total, $active);

    return $runner->{_calc_cache} = {
        max      => $max,
        assigned => $assigned,
        active   => $active,
        total    => $total,
        wants    => $wants,
    };
}

sub _redistribute {
    my $self = shift;
    my ($state) = @_;

    my $max_run = $self->{+MAX_SLOTS_PER_RUN};

    my $wanted = 0;
    for my $runner (values %{$state->{+RUNNERS}}) {
        my $calcs = $self->_runner_calcs($runner);
        $runner->{allotment} = $calcs->{wants};
        $wanted += $calcs->{wants};
    }

    # Everyone gets what they want!
    my $max = $self->{+MAX_SLOTS};
    return if $wanted <= $max;

    my $meth = $self->{+ALGORITHM};

    return $self->$meth($state);
}

sub _redistribute_first {
    my $self = shift;
    my ($state) = @_;

    my $min = $self->{+MIN_SLOTS_PER_RUN};
    my $max = $self->{+MAX_SLOTS};

    my $c = 0;
    for my $runner (sort { $a->{added} <=> $b->{added} } values %{$state->{+RUNNERS}}) {
        my $calcs = $self->_runner_calcs($runner);
        my $wants = $calcs->{wants};

        if ($max >= $wants) {
            $runner->{allotment} = $wants;
        }
        else {
            $runner->{allotment} = max($max, $min, 0);
        }

        $max -= $runner->{allotment};

        $c++;
    }

    return;
}

sub _redistribute_fair {
    my $self = shift;
    my ($state) = @_;

    my $runs = scalar keys %{$state->{+RUNNERS}};

    # Avoid a divide by 0 below.
    return unless $runs;

    my $total = $self->{+MAX_SLOTS};
    my $min   = $self->{+MIN_SLOTS_PER_RUN};

    my $used = 0;
    for my $runner (values %{$state->{+RUNNERS}}) {
        my $calcs = $self->_runner_calcs($runner);

        # We never want less than the 'active' number
        my $set = $calcs->{active};

        # If min is greater than the active number and there are todo tests, we
        # use the min instead.
        $set = $min if $set < $min && $runner->{todo};

        $runner->{allotment} = $set;
        $used += $set;
    }

    my $free = $total - $used;
    return unless $free >= 1;

    # Is there a more efficient way to do this? Yikes!
    my @runners = values %{$state->{+RUNNERS}};
    while ($free > 0) {
        @runners = sort { $a->{allotment} <=> $b->{allotment} || $a->{added} <=> $b->{added} }
                   grep { my $c = $self->_runner_calcs($_); $c->{wants} > $_->{allotment} }
                   @runners;

        $free--;
        $runners[0]->{allotment}++;
    }

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Resource::SharedJobSlots::State - shared state for job slots

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

Copyright 2022 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
