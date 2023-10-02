package Test2::Harness::Runner::Resource::SharedJobSlots::State;
use strict;
use warnings;

our $VERSION = '1.000155';

use Test2::Harness::Util::File::JSON;
use Scalar::Util qw/weaken/;
use Time::HiRes qw/time/;
use List::Util qw/first min sum0 max/;
use Carp qw/croak confess carp/;
use Fcntl qw/:flock SEEK_END/;
use Errno qw/EINTR EAGAIN ESRCH/;

use Test2::Harness::Util::HashBase qw{
    <state_file <state_fh
    <state_umask
    <runner_id <name <dir <runner_pid
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
    +transaction

    <registered
    <unregistered
};

BEGIN {
    for my $term (qw/runners local/) {
        my $val   = "$term";
        my $const = uc($term);
        no strict 'refs';
        *{$const} = sub() { $val };
    }
}

sub TIMEOUT() { 300 }         # Timeout runs if they do not update at least every 5 min

sub init {
    my $self = shift;

    croak "'state_file' is a required attribute"        unless $self->{+STATE_FILE};
    croak "'max_slots' is a required attribute"         unless $self->{+MAX_SLOTS};
    croak "'max_slots_per_job' is a required attribute" unless $self->{+MAX_SLOTS_PER_JOB};
    croak "'max_slots_per_run' is a required attribute" unless $self->{+MAX_SLOTS_PER_RUN};

    $self->{+MY_MAX_SLOTS}         //= $self->{+MAX_SLOTS};
    $self->{+MY_MAX_SLOTS_PER_JOB} //= $self->{+MAX_SLOTS_PER_JOB};

    $self->{+MIN_SLOTS_PER_RUN} //= 0;

    $self->{+STATE_UMASK} //= 0007;

    $self->{+NAME} //= $self->{+RUNNER_ID};

    $self->{+ALGORITHM} //= '_redistribute_fair';
}

sub init_state {
    my $self = shift;
    return { RUNNERS() => {} };
}

sub state { shift->transaction('r') }

sub transaction {
    my $self = shift;
    my ($mode, $cb, @args) = @_;

    $mode //= 'r';

    my $write = $mode eq 'w' || $mode eq 'rw';
    my $read  = $mode eq 'ro' || $mode eq 'r';
    croak "mode must be 'w', 'rw', 'r', or 'ro', got '$mode'" unless $write || $read;

    confess "Write mode requires a 'runner_id'"  if $write && !$self->{+RUNNER_ID};
    confess "Write mode requires a 'runner_pid'" if $write && !$self->{+RUNNER_PID};

    my ($lock, $state, $local);
    if ($state = $self->{+TRANSACTION}) {
        $local = $state->{+LOCAL};

        confess "Attempted a 'write' transaction inside of a read-only transaction"
            if $write && !$local->{write};
    }
    else {
        my $oldmask = umask($self->{+STATE_UMASK});

        my $ok = eval {
            my $lockf = "$self->{+STATE_FILE}.LOCK";

            open($lock, '>>', $lockf) or die "Could not open lock file '$lockf': $!";
            while (1) {
                last if flock($lock, $write ? LOCK_EX : LOCK_SH);
                next if $! == EINTR || $! == EAGAIN;
                warn "Could not get lock: $!";
            }

            $state = $self->_read_state();
            $local = $state->{+LOCAL} = {
                lock  => $lock,
                mode  => $mode,
                write => $write,
                stack => [{cb => $cb, args => \@args}],
            };

            weaken($state->{+LOCAL}->{lock});

            1;
        };
        my $err = $@;
        umask($oldmask);
        die $err unless $ok;
    }

    local @{$local}{qw/write mode stack/} = ($write, $mode, [@{$local->{stack}}, {cb => $cb, args => \@args}])
        if $self->{+TRANSACTION};

    local $self->{+TRANSACTION} = $state;

    if ($write) {
        if ($self->{+REGISTERED}) {
            $self->_verify_registration($state);
        }
        else {
            $self->_update_registration($state);
        }
    }
    $self->_clear_old_registrations($state);

    my $out;
    my $ok  = eval { $out = $cb ? $self->$cb($state, @args) : $state; 1 };
    my $err = $@;

    if ($ok && $write) {
        $self->_clear_old_registrations($state);
        $self->_update_registration($state) unless $self->{+UNREGISTERED};
        $self->_write_state($state);
    }

    if ($lock) {
        flock($lock, LOCK_UN) or die "Could not release lock: $!";
    }

    die $err unless $ok;

    return $out;
}

sub _read_state {
    my $self = shift;

    return $self->init_state unless -e $self->{+STATE_FILE};

    my $file = Test2::Harness::Util::File::JSON->new(name => $self->{+STATE_FILE});

    my ($ok, $err);
    for (1 .. 5) {
        my $state;
        $ok = eval { $state = $file->maybe_read(); 1};
        $err = $@;

        return $state ||= $self->init_state if $ok;

        sleep 0.2;
    }

    warn "Corrupted state? Resetting state to initial. Error that caused this was:\n======\n$err\n======\n";

    return $self->init_state;
}

sub _write_state {
    my $self = shift;
    my ($state) = @_;

    my $state_copy = {%$state};

    my $local = delete $state_copy->{+LOCAL};

    confess "Attempted write with no lock" unless $local->{lock};
    confess "Attempted write with a read-only lock" unless $local->{write};

    my $oldmask = umask($self->{+STATE_UMASK});
    my $ok = eval {
        my $file = Test2::Harness::Util::File::JSON->new(name => $self->{+STATE_FILE});
        $file->rewrite($state_copy);
        1;
    };
    my $err = $@;

    umask($oldmask);

    die $err unless $ok;
}

sub update_registration { $_[0]->transaction(rw => '_update_registration') }
sub remove_registration { $_[0]->transaction(rw => '_update_registration', remove => 1) }

sub _update_registration {
    my $self = shift;
    my ($state, %params) = @_;

    my $runner_id  = $self->{+RUNNER_ID};
    my $runner_pid = $self->{+RUNNER_PID};
    my $entry      = $state->{runners}->{$runner_id} //= $state->{runners}->{$runner_id} = {
        runner_id  => $runner_id,
        runner_pid => $runner_pid,
        name       => $self->{+NAME},
        dir        => $self->{+DIR},
        user       => $ENV{USER},
        added      => time,

        todo      => 0,
        allocated => 0,
        allotment => 0,
        assigned  => {},

        max_slots         => $self->{+MY_MAX_SLOTS},
        max_slots_per_job => $self->{+MY_MAX_SLOTS_PER_JOB},
    };

    # Update our last checking time
    $entry->{seen} = time;

    $self->{+REGISTERED} = 1;

    return $state unless $params{remove};

    $self->{+UNREGISTERED} = 1;
    $entry->{remove} = 1;

    return $state;
}

sub _verify_registration {
    my $self = shift;
    my ($state) = @_;

    return unless $self->{+REGISTERED};

    my $runner_id = $self->{+RUNNER_ID};
    my $entry  = $state->{+RUNNERS}->{$runner_id};

    # Do not allow for a new expiration. If the state has already expired us we will see it.
    $entry->{seen} = time if $entry;

    return unless $self->{+UNREGISTERED} //= $self->_entry_expired($entry);

    confess "Shared slot registration expired";
}

sub _entry_expired {
    my $self = shift;
    my ($entry) = @_;

    return 1 unless $entry;
    return 1 if $entry->{remove};

    if (my $pid = $entry->{runner_pid}) {
        my $ret = kill(0, $pid);
        my $err = $!;
        return 1 if $ret == 0 && $! == ESRCH;
    }

    my $seen  = $entry->{seen} or return 1;
    my $delta = time - $seen;

    return 1 if $delta > TIMEOUT();

    return 0;
}

sub _clear_old_registrations {
    my $self = shift;
    my ($state) = @_;

    my $runners  = $state->{+RUNNERS}     //= {};

    my (%removed);
    for my $entry (values %$runners) {
        $entry->{remove} = 1 if $self->_entry_expired($entry);
        next unless $entry->{remove};

        my $runner_id = $entry->{runner_id};

        $self->{+UNREGISTERED} = 1 if $runner_id eq $self->{+RUNNER_ID};

        delete $runners->{$runner_id};

        $removed{$runner_id}++;
    }

    return \%removed;
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

sub _allocate_slots {
    my $self = shift;
    my ($state, %params) = @_;

    my $entry = $state->{runners}->{$self->{+RUNNER_ID}};
    delete $entry->{_calc_cache};

    my $job_id = $params{job_id};
    my $con    = $params{con};
    my ($min, $max) = @$con;
    $self->_runner_todo($entry, $job_id => $max);

    my $allocated = $entry->{allocated};

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

    my $entry = $state->{runners}->{$self->{+RUNNER_ID}};
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

    my $entry = $state->{runners}->{$self->{+RUNNER_ID}};

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
