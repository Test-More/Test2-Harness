package Test2::Harness2::Resource::JobCount;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use List::Util qw/min/;
use Time::HiRes qw/time/;

use Object::HashBase qw{
    <slots
    <used
    <assignments
    +paused
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Resource';

sub is_job_limiter { 1 }

sub resource_name { 'jobcount' }

sub init {
    my $self = shift;

    my $slots = $self->{+SLOTS};
    croak "'slots' is required and must be a positive integer"
        unless defined $slots && $slots =~ m/^\d+$/ && $slots > 0;

    $self->{+USED}        //= 0;
    $self->{+ASSIGNMENTS} //= {};
}

# JobCount has no backing service, so there is nothing to "break". The
# role's is_broken / is_permanent_broken defaults (both 0) are
# correct, and the role's croaking defaults for mark_broken /
# mark_permanent_broken catch any caller that accidentally tries to
# transition this resource into a broken state.
#
# Pausing is still supported so an operator (or test) can halt
# scheduling without touching slot state.
sub is_paused    { $_[0]->{+PAUSED} ? 1 : 0 }
sub mark_paused  { $_[0]->{+PAUSED} = 1 }
sub mark_resumed { $_[0]->{+PAUSED} = 0 }

sub _job_slot_bounds {
    my ($self, $job, %p) = @_;

    # Synthesized skip/fail launches pass min/max overrides directly
    # so the assignment doesn't care what the real test file declared
    # (a one-liner "skip_all" or "die" only needs a single slot, even
    # if the test file normally asks for eight).
    my $tf  = $job->test_file;
    my $min = $p{min} // $tf->min_slots || 1;
    my $max = $p{max} // $tf->max_slots;
    $max = $min unless defined $max;

    return ($min, $max);
}

sub available {
    my ($self, %p) = @_;

    my $job = $p{job} or croak "'job' is required";

    my ($min, $max) = $self->_job_slot_bounds($job, %p);
    my $need = $p{need} // $min;

    # Permanently unsatisfiable: the resource pool is smaller than the job's
    # minimum. Return -1 so the scheduler can mark the job as skipped rather
    # than deferring it forever.
    return -1 if $self->{+SLOTS} < $min;

    my $free = $self->{+SLOTS} - $self->{+USED};

    return 0 if $free < 1;
    return 0 if $free < $min;
    return 0 if $free < $need;

    # max_slots <= 0 means "as many as are free up to min..free".
    $max = $free if $max < 1;

    my $grant = min($max, $free);
    $grant = $need if $need > $min && $need <= $grant;

    return $grant;
}

sub assign {
    my ($self, %p) = @_;

    my $id  = $p{id}  or croak "'id' is required";
    my $job = $p{job} or croak "'job' is required";
    my $env = $p{env} or croak "'env' hashref is required";

    croak "duplicate assign for id '$id'"
        if exists $self->{+ASSIGNMENTS}->{$id};

    my $count = $self->available(%p);
    croak "cannot assign id '$id': resource unavailable"
        unless $count > 0;

    $self->{+USED} += $count;
    $self->{+ASSIGNMENTS}->{$id} = {
        job   => $job,
        count => $count,
        stamp => time,
    };

    $env->{T2_HARNESS_MY_JOB_CONCURRENCY} = $count;

    # The scheduler does not consume this return value (assign is
    # fire-and-forget on the scheduler's side). It is handed back for
    # tests that want to assert the granted slot count without reaching
    # into the assignment hash.
    return $count;
}

sub release {
    my ($self, %p) = @_;

    my $id = $p{id} or croak "'id' is required";

    my $assign = delete $self->{+ASSIGNMENTS}->{$id}
        or croak "invalid release id '$id'";

    $self->{+USED} -= $assign->{count};

    # See assign() above: the scheduler ignores this return value; it
    # exists for tests that want to assert the released slot count.
    return $assign->{count};
}

sub status {
    my $self = shift;

    my $free = $self->{+SLOTS} - $self->{+USED};

    my @assigned;
    for my $id (sort keys %{$self->{+ASSIGNMENTS} // {}}) {
        my $a  = $self->{+ASSIGNMENTS}->{$id};
        my $tf = $a->{job}->test_file;
        push @assigned => {
            id    => $id,
            count => $a->{count},
            stamp => $a->{stamp},
            age   => time - $a->{stamp},
            test  => $tf->relative,
        };
    }

    return {
        resource    => $self->resource_name,
        slots       => $self->{+SLOTS},
        used        => $self->{+USED},
        free        => $free,
        broken      => $self->is_broken,
        paused      => $self->is_paused,
        permanent   => $self->is_permanent_broken,
        assignments => \@assigned,
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Resource::JobCount - Limit on concurrent test jobs.

=head1 DESCRIPTION

Caps the total number of jobs the harness service will run concurrently.
The harness requires at least one C<is_job_limiter> resource to be
configured; without one it falls back to an instance of this class with
C<slots =E<gt> 1>, preserving the legacy "one at a time" behaviour.

Each job declares its slot requirements on its L<Test2::Harness2::Role::TestFile>
(C<min_slots> / C<max_slots>). The resource grants an integer count from
that range, writes it to C<T2_HARNESS_MY_JOB_CONCURRENCY> in the child
environment, and tracks the outstanding assignment until C<release> is
called.

=head1 ATTRIBUTES

=over 4

=item slots (required)

Positive integer; the total concurrency cap.

=back

=head1 METHODS

Implements L<Test2::Harness2::Role::Resource>. See that role for return
value conventions on C<available>.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
