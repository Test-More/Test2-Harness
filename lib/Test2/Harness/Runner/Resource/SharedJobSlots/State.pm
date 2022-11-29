package Test2::Harness::Runner::Resource::SharedJobSlots::State;
use strict;
use warnings;

our $VERSION = '1.000136';

use Test2::Harness::Util::File::JSON;
use Scalar::Util qw/weaken/;
use Time::HiRes qw/time/;
use List::Util qw/first/;
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

    <request_sort

    <ready_assignments
    +transaction

    <registered
    <unregistered
};

BEGIN {
    for my $term (qw/runners assigned queue pending local ords/) {
        my $val   = "$term";
        my $const = uc($term);
        no strict 'refs';
        *{$const} = sub() { $val };
    }
}

sub TIMEOUT() { 300 }         # Timeout runs if they do not update at least every 5 min
sub RELEASE() { 'release' }
sub REQUEST() { 'request' }

sub init {
    my $self = shift;

    croak "'state_file' is a required attribute"        unless $self->{+STATE_FILE};
    croak "'max_slots' is a required attribute"         unless $self->{+MAX_SLOTS};
    croak "'max_slots_per_job' is a required attribute" unless $self->{+MAX_SLOTS_PER_JOB};
    croak "'max_slots_per_run' is a required attribute" unless $self->{+MAX_SLOTS_PER_RUN};

    $self->{+STATE_UMASK} //= 0007;

    $self->{+NAME} //= $self->{+RUNNER_ID};

    $self->{+REQUEST_SORT} //= 'request_sort_fair';
}

sub init_state {
    my $self = shift;

    return {
        RUNNERS()  => {},                             # Lookup for runner specific info
        ASSIGNED() => {},                             # Active slot assignments
        QUEUE()    => {},                             # Assignments ready to be made, awaiting runner to acknowledge it has grabbed them
        PENDING()  => [],                             # Slot requests that have been made, but slots are not yet available
        ORDS()     => {runners => 1, pending => 1},
    };
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

    $self->_verify_registration($state) if $write && $self->{+REGISTERED};
    $self->_clear_old_registrations($state);

    my $out;
    my $ok  = eval { $out = $cb ? $self->$cb($state, @args) : $state; 1 };
    my $err = $@;

    if ($ok && $write) {
        $self->_clear_old_registrations($state);
        $self->_update_registration($state) unless $self->{+UNREGISTERED};
        $self->_advance($state);
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

    my $file  = Test2::Harness::Util::File::JSON->new(name => $self->{+STATE_FILE});
    my $state = $file->maybe_read() || $self->init_state;

    return $state;
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
        $file->write($state_copy);
        1;
    };
    my $err = $@;

    umask($oldmask);

    die $err unless $ok;
}

sub status {
    my $self = shift;
    my ($mode) = @_;
    $mode //= 'ro';

    my $state = $self->transaction($mode);
    my ($used, $available, $pend) = $self->_status($state);

    $used = {%$used};
    $pend = {%$pend};

    return {
        state   => $state,
        used    => $used,
        pending => $pend,

        available_count => $available               // 0,
        used_count      => delete $used->{__ALL__}  // 0,
        request_count   => delete $pend->{+REQUEST} // 0,
        release_count   => delete $pend->{+RELEASE} // 0,
    };
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
        ord        => $state->{+ORDS}->{runners}++,
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

sub release_slots {
    my $self = shift;
    my ($job_id) = @_;

    croak "'job_id' must be specified" unless $job_id;

    my $entry = $self->transaction(rw => '_release_slots', $job_id);

    return { %$entry };
}

sub _release_slots {
    my $self = shift;
    my ($state, $job_id) = @_;

    confess "'job_id' must be specified" unless $job_id;

    my $runner_id = $self->{+RUNNER_ID};

    my $entry = {
        type   => RELEASE(),
        user   => $ENV{USER},
        runner_id => $runner_id,
        job_id => $job_id,
        ord    => 0,
    };

    # Releases are added to the start
    unshift @{$state->{+PENDING}} => $entry;
    return $entry;
}

sub ready_request_list {
    my $self = shift;
    return keys %{$self->state->{+QUEUE}->{$self->{+RUNNER_ID}}};
}

sub check_ready_request {
    my $self = shift;
    my ($job_id) = @_;
    return $self->state->{+QUEUE}->{$self->{+RUNNER_ID}}->{$job_id} ? 1 : 0;
}

sub get_ready_request {
    my $self = shift;
    my ($job_id) = @_;

    return $self->transaction('rw' => '_get_ready_request', $job_id);
}

sub _get_ready_request {
    my $self = shift;
    my ($state, $job_id) = @_;

    for (0 .. 1) {
        $self->_advance($state) if $_;

        my $runner_id = $self->{+RUNNER_ID};

        next unless $state->{+QUEUE}->{$runner_id};
        my $entry = delete $state->{+QUEUE}->{$runner_id}->{$job_id} or next;

        delete $state->{+QUEUE}->{$runner_id} unless keys %{$state->{+QUEUE}->{$runner_id}};

        $entry->{assign_stamp} = time;
        $entry->{stage} = ASSIGNED();
        $state->{+ASSIGNED}->{$runner_id}->{$job_id} = $entry;

        return { %$entry };
    }

    return undef;
}

sub request_slots {
    my $self   = shift;
    my %params = @_;

    my $job_id = $params{job_id} or croak "'job_id' must be specified";
    my $count  = $params{count} or croak "'count' must be specified";

    carp "Too many slots requested ($count > $self->{+MAX_SLOTS_PER_JOB})"
        if $count > $self->{+MAX_SLOTS_PER_JOB};

    my $state = $self->transaction(rw => '_request_slots', %params, runner_id => $self->{+RUNNER_ID});

    return $state->{+QUEUE}->{$self->{+RUNNER_ID}}->{$job_id} ? 1 : 0;
}

sub _request_slots {
    my $self = shift;
    my ($state, %params) = @_;

    confess "'count' must be specified" unless $params{count};

    my $job_id = $params{job_id} or confess "'job_id' must be specified";
    my $runner_id = $self->{+RUNNER_ID};

    return $state if $state->{+QUEUE}->{$runner_id}
                  && $state->{+QUEUE}->{$runner_id}->{$job_id};

    my $common = {
        %params,
        type   => REQUEST(),
        user   => $ENV{USER},
        runner_id => $runner_id,
    };

    # See if we already have a pending request to modify.
    # Only 1 pending request is allowed per run+job at a time
    my $req = first { $_->{type} eq REQUEST() && $_->{job_id} eq $job_id && $_->{runner_id} eq $runner_id } @{$state->{pending}};

    if ($req) {
        %$req = (%$req, %$common);
    }
    else {
        push @{$state->{pending}} => {
            %$common,
            ord    => $state->{+ORDS}->{pending}++,
            stage  => PENDING(),
        };
    }

    return $state;
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
    my $pending  = $state->{+PENDING}     //= [];
    my $queue    = $state->{+QUEUE}       //= {};
    my $assigned = $state->{+ASSIGNED}    //= {};

    my (%removed);
    for my $entry (values %$runners) {
        $entry->{remove} = 1 if $self->_entry_expired($entry);
        next unless $entry->{remove};

        my $runner_id = $entry->{runner_id};

        $self->{+UNREGISTERED} = 1 if $runner_id eq $self->{+RUNNER_ID};

        delete $runners->{$runner_id};
        delete $queue->{$runner_id};
        delete $assigned->{$runner_id};

        $removed{$runner_id}++;
    }

    @$pending = grep { !$removed{$_->{runner_id}} } @$pending;

    return \%removed;
}

sub _status {
    my $self = shift;
    my ($state, %params) = @_;

    my $pend      = $state->{+LOCAL}->{pending};
    my $used      = $state->{+LOCAL}->{used};
    my $available = $state->{+LOCAL}->{available};

    return ($used, $available, $pend)
        if !$params{refresh} && $pend && $used && $available;

    my $queue    = $state->{+QUEUE}       //= {};
    my $assigned = $state->{+ASSIGNED}    //= {};

    $used = {__ALL__ => 0};
    for my $entry (map { values(%$_) } values(%$queue), values(%$assigned)) {
        $used->{__ALL__} += $entry->{count};
        $used->{$entry->{runner_id}} += $entry->{count};
    }

    $pend = {REQUEST() => 0, RELEASE() => 0};
    for my $item (@{$state->{+PENDING} //= []}) {
        my $c = abs($item->{count});
        $pend->{$item->{type}} += $c;
        $pend->{$item->{runner_id}} += $c if $item->{type} eq REQUEST();
    }

    $available = $self->{+MAX_SLOTS} - $used->{__ALL__};

    $state->{+LOCAL}->{pending}   = $pend;
    $state->{+LOCAL}->{used}      = $used;
    $state->{+LOCAL}->{available} = $available;

    return ($used, $available, $pend);
}

sub _advance {
    my $self = shift;
    my ($state) = @_;

    my $pending  = $state->{+PENDING}     //= [];
    my $queue    = $state->{+QUEUE}       //= {};
    my $assigned = $state->{+ASSIGNED}    //= {};

    # Clear free slot(s)
    # Free slots are always unshifted onto the start of the pending array
    while (@$pending && $pending->[0]->{type} eq RELEASE()) {
        my $item = shift @$pending;

        my $runner_id = $item->{runner_id};
        my $job_id    = $item->{job_id};

        # Might be releasing something that has only been queued, not assigned
        delete $queue->{$runner_id}->{$job_id} if $queue->{$runner_id};
        delete $queue->{$runner_id} unless keys %{$queue->{$runner_id}};

        # Might be releasing something that is pending, not even queued yet.
        @$pending = grep { !($_->{runner_id} eq $runner_id && $_->{job_id} eq $job_id) } @$pending;

        delete $assigned->{$runner_id}->{$job_id} if $assigned->{$runner_id};
    }

    my ($used, $available) = $self->_status($state, refresh => 1);
    my @order = @$pending;

    # Pick the next slot assignment(s)
    while (@order && $available && $available > 0) {
        my $item;

        # Sort the current requests, but first filter out any that need more slots than are available, or where the run is at or over the per run limit.
        # We need to re-calculate this every iteration because the numbewr of available slots changes.
        my $sort = $self->{+REQUEST_SORT};
        ($item, @order) = sort { $self->$sort($state, $a, $b) } grep { $_->{count} <= $available && ($used->{$_->{runner_id}} //= 0) < $self->{+MAX_SLOTS_PER_RUN} } @order;
        last unless $item;

        delete $item->{type};
        $item->{stage} = QUEUE();
        my $runner_id = $item->{runner_id};

        $queue->{$runner_id}->{$item->{job_id}} = $item;

        my $count = $item->{count};
        $available       -= $count;
        $used->{__ALL__} += $count;
        $used->{$runner_id} += $count;
    }

    # Clean up the pending
    @$pending = grep { $_->{stage} eq PENDING() } @$pending;

    return $state;
}

sub request_sort_fair {
    my $self = shift;
    my ($state, $a, $b) = @_;

    return $self->_request_sort_by_used_slots(@_) || $self->_request_sort_by_run_order(@_) || $self->_request_sort_by_request_order(@_) || $self->_our_request_first(@_);
}

sub request_sort_first {
    my $self = shift;
    my ($state, $a, $b) = @_;

    return $self->_request_sort_by_run_order(@_) || $self->_request_sort_by_used_slots(@_) || $self->_request_sort_by_request_order(@_) || $self->_our_request_first(@_);
}

sub request_sort_greedy {
    my $self = shift;
    my ($state, $a, $b) = @_;

    return $self->_our_request_first(@_) || $self->_request_sort_by_request_order(@_) || $self->_request_sort_by_run_order(@_) || $self->_request_sort_by_used_slots(@_);
}

sub _our_request_first {
    my $self = shift;
    my ($state, $a, $b) = @_;

    return 0  if $a->{runner_id} eq $b->{runner_id};
    return -1 if $a->{runner_id} eq $self->{+RUNNER_ID};
    return 1  if $b->{runner_id} eq $self->{+RUNNER_ID};
    return 0;
}

sub _request_sort_by_used_slots {
    my $self = shift;
    my ($state, $a, $b) = @_;

    # Runs with the least assigned slots come first
    my $used = $state->{+LOCAL}->{used} or confess "No slot usage data!";
    return ($used->{$a->{runner_id}} //= 0) <=> ($used->{$b->{runner_id}} //= 0);
}

sub _request_sort_by_run_order {
    my $self = shift;
    my ($state, $a, $b) = @_;

    my $runners = $state->{+RUNNERS}       or confess "No runner data!";
    return $runners->{$a->{runner_id}}->{ord} <=> $runners->{$b->{runner_id}}->{ord};
}

sub _request_sort_by_request_order {
    my $self = shift;
    my ($state, $a, $b) = @_;

    return $a->{ord} <=> $b->{ord};
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
