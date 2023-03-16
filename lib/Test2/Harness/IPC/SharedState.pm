package Test2::Harness::IPC::SharedState;
use strict;
use warnings;

our $VERSION = '1.000146';

use Test2::Harness::Util::File::JSON;
use Scalar::Util qw/weaken/;
use Time::HiRes qw/time/;
use Carp qw/croak confess/;
use Fcntl qw/:flock/;
use Errno qw/EINTR EAGAIN ESRCH/;

use Test2::Harness::Util::HashBase qw{
    <state_file <state_fh <state_umask

    <access_id <access_pid <access_meta
    <timeout

    +transaction

    <registered <unregistered

    +cache +no_cache
};

use constant LOCAL  => 'local';
use constant ACCESS => 'access';

sub state_class {}

sub init {
    my $self = shift;

    croak "'state_file' is a required attribute" unless $self->{+STATE_FILE};

    $self->{+TIMEOUT}     //= 300;    # Timeout runs if they do not update at least every 5 min
    $self->{+STATE_UMASK} //= 0007;
}

sub state { shift->transaction('r') }
sub data  { shift->transaction('r') }

sub init_state {
    my $self = shift;
    return {timeout => $self->{+TIMEOUT}};
}

sub _times {
    my $self = shift;
    my $file = $self->{+STATE_FILE};
    my (undef, undef, undef, undef, undef, undef, undef, undef, undef, $mtime, $ctime) = stat($file);
    return [$mtime, $ctime];
}

sub transaction {
    my $self = shift;
    my ($mode, $cb, @args) = @_;

    $mode //= 'r';

    my $write = $mode eq 'w'  || $mode eq 'rw';
    my $read  = $mode eq 'ro' || $mode eq 'r';
    croak "mode must be 'w', 'rw', 'r', or 'ro', got '$mode'" unless $write || $read;

    if ($write) {
        confess "Write mode requires a 'access_id'"  unless $self->access_id;
        my $pid = $self->access_pid or confess "Write mode requires a 'access_pid'";
        confess "Access PID mismatch ($pid vs $$)" unless $$ == $pid;
    }

    my ($lock, $state, $local, $new);
    if ($state = $self->{+TRANSACTION}) {
        $new = 0;
        $local = $state->{+LOCAL};

        confess "Attempted a 'write' transaction inside of a read-only transaction"
            if $write && !$local->{write};
    }
    else {
        my $cache = $self->{+CACHE};
        if ($read && $cache) {
            my $times = $self->_times();
            if ($cache->[0] eq $times->[0] && $cache->[1] eq $times->[1]) {
                $state = $cache->[2];
            }
            else {
                delete $self->{+CACHE};
            }
        }

        $new = 1;
        my $oldmask = umask($self->{+STATE_UMASK});

        unless ($state) {
            my $ok = eval {
                my $lockf = "$self->{+STATE_FILE}.LOCK";

                open($lock, '>>', $lockf) or die "Could not open lock file '$lockf': $!";
                while (1) {
                    last if flock($lock, $write ? LOCK_EX : LOCK_SH);
                    next if $! == EINTR || $! == EAGAIN;
                    warn "Could not get lock: $!";
                }

                $state = $self->_read_state();
                1;
            };
            my $err = $@;
            umask($oldmask);
            die $err unless $ok;
        }

        $local = $state->{+LOCAL} = {
            lock  => $lock,
            mode  => $mode,
            write => $write,
            stack => [{cb => $cb, args => \@args}],
        };

        weaken($state->{+LOCAL}->{lock});
    }

    local @{$local}{qw/write mode stack/} = ($write, $mode, [@{$local->{stack}}, {cb => $cb, args => \@args}])
        if $self->{+TRANSACTION};

    local $self->{+TRANSACTION} = $state;

    if ($new) {
        if ($write) {
            if ($self->{+REGISTERED}) {
                $self->_verify_registration($state);
            }
            else {
                $self->_update_registration($state);
            }
        }
        $self->_clear_old_registrations($state);
    }

    my $out;
    my $ok  = eval { $out = $cb ? $self->$cb($state, @args) : $state; 1 };
    my $err = $@;

    if ($ok && $write && $new) {
        $self->_clear_old_registrations($state);
        $self->_update_registration($state) unless $self->{+UNREGISTERED};
        $self->_write_state($state);
    }

    if ($lock) {
        $self->{+CACHE} //= [@{$self->_times}, $state] unless $self->{+NO_CACHE};
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
        $ok  = eval { $state = $file->maybe_read(); 1 };
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

    confess "Attempted write with no lock"          unless $local->{lock};
    confess "Attempted write with a read-only lock" unless $local->{write};

    my $oldmask = umask($self->{+STATE_UMASK});
    my $ok      = eval {
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

    my $access_id = $self->{+ACCESS_ID};
    my $entry     = $state->{+ACCESS}->{$access_id} //= {
        %{$self->{+ACCESS_META} // {}},
        access_id  => $access_id,
        access_pid => $self->{+ACCESS_PID},
        user       => $ENV{USER},
        added      => time,
    };

    # Update our last checkin time
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

    my $access_id = $self->{+ACCESS_ID};
    my $entry     = $state->{+ACCESS}->{$access_id};

    # Do not allow for a new expiration. If the state has already expired us we will see it.
    $entry->{seen} = time if $entry;

    return unless $self->{+UNREGISTERED} //= $self->_entry_expired($entry);

    confess "Shared state registration expired";
}

sub _entry_expired {
    my $self = shift;
    my ($entry) = @_;

    return 1 unless $entry;
    return 1 if $entry->{remove};

    if (my $pid = $entry->{+ACCESS_PID}) {
        my $ret = kill(0, $pid);
        my $err = $!;
        return 1 if $ret == 0 && $! == ESRCH;
    }

    my $seen  = $entry->{seen} or return 1;
    my $delta = time - $seen;

    return 1 if $delta > $self->{+TIMEOUT};

    return 0;
}

sub _clear_old_registrations {
    my $self = shift;
    my ($state) = @_;

    my $access = $state->{+ACCESS} //= {};

    my (%removed);
    for my $entry (values %$access) {
        $entry->{remove} = 1 if $self->_entry_expired($entry);
        next unless $entry->{remove};

        my $access_id = $entry->{access_id};

        $self->{+UNREGISTERED} = 1 if $access_id eq $self->{+ACCESS_ID};

        delete $access->{$access_id};

        $removed{$access_id}++;
    }

    return [keys %removed];
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::IPC::SharedState - IPC Shared State

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
