package Resource;
use strict;
use warnings;

use parent 'App::Yath::Resource';

my $limit = 2;

sub applicable { 1 }

my $no_slots_msg = 0;
sub available {
    my $self = shift;
    my ($id, $job) = @_;

    for my $slot (1 .. $limit) {
        return 1 unless defined $self->{$slot};
    }

    $self->message("No Slots") unless $no_slots_msg++;
    return 0;
}

sub assign {
    my $self = shift;
    my ($id, $job, $env) = @_;

    for my $slot (1 .. $limit) {
        next if defined $self->{$slot};

        $self->message("Assigned: $id - $slot");
        $env->{RESOURCE_TEST} = $slot;
        push @{$job->args} => $slot;

        $self->{$slot} = $id;
        $self->{$id} = $slot;
        return $env;
    }

    die "Error, no slots to assign";
}

sub release {
    my $self = shift;
    my ($id, $job) = @_;

    my $slot = delete $self->{$id};
    delete $self->{$slot};
    $self->message("Release: $id - $slot");
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

        print STDERR "$$ - $0\n";
    }

    print STDERR "$$ - $msg\n";
}

1;
