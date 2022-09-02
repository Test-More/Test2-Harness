package Resource;
use strict;
use warnings;

use parent 'Test2::Harness::Runner::Resource';

my $limit = 2;

my $no_slots_msg = 0;
sub available {
    my $self = shift;
    my ($task) = @_;

    for my $slot (1 .. $limit) {
        return 1 unless defined $self->{$slot};
    }

    $self->message("No Slots") unless $no_slots_msg++;
    return 0;
}

sub assign {
    my $self = shift;
    my ($task, $state) = @_;

    for my $slot (1 .. $limit) {
        next if defined $self->{$slot};

        $self->message("Assigned: $task->{job_id} - $slot");
        $state->{record} = $slot;
        $state->{env_vars}->{RESOURCE_TEST} = $slot;
        push @{$state->{args}} => $slot;

        return;
    }

    die "Error, no slots to assign";
}

sub record {
    my $self = shift;
    my ($job_id, $slot) = @_;

    $self->message("Record: $job_id - $slot");
    $self->{$slot} = $job_id;
    $self->{$job_id} = $slot;
}

sub release {
    my $self = shift;
    my ($job_id) = @_;

    my $slot = delete $self->{$job_id};
    delete $self->{$slot};
    $self->message("Release: $job_id - $slot");
}

sub cleanup {
    my $self = shift;

    $self->message("RESOURCE CLEANUP");
}

my $pid;
sub message {
    my $self = shift;
    my ($msg) = @_;

    if (!$pid || $$ != $pid) {
        $pid = $$;

        print "$$ - $0\n";
    }

    print "$$ - $msg\n";
}

1;
