package Test2::Harness::Auditor;
use strict;
use warnings;

use Test2::Harness::Util::JSON qw/decode_json/;

use Test2::Harness::Event;
use Test2::Harness::Auditor::Watcher;

use Test2::Harness::Util::HashBase qw{
    <action
    <run_id

    +broken

    <watchers
    <queued
};

sub init {
    my $self = shift;

    $self->{+WATCHERS} //= {};
}

sub process {
    my $self = shift;

    while (my $line = <STDIN>) {
        my $data = decode_json($line);
        last unless defined $data;
        my $e = Test2::Harness::Event->new($data);

        my @events = $self->process_event($e);

        $self->{+ACTION}->($_) for @events;
    }
}

sub process_event {
    my $self = shift;
    my ($e) = @_;

    my $job_id = $e->job_id;

    # Do nothing for non-job events
    return $e unless $job_id;

    my $f = $e->facet_data;

    if (my $task = $f->{harness_job_queued}) {
        $self->{+WATCHERS}->{$job_id} //= [];
        $self->{+QUEUED}->{$job_id} = $task;
        return $e;
    }

    my $tries = $self->{+WATCHERS}->{$job_id} or return $self->broken($e, "Never saw queue entry");

    if (my $job = $f->{harness_job}) {
        push @$tries => Test2::Harness::Auditor::Watcher->new(job => $job);
    }

    my $watcher = $tries->[-1] or return $self->broken($e, "never saw harness_job facet");

    return $watcher->process($e);
}

sub broken {
    my $self = shift;
    my ($e, $message) = @_;

    $self->{+BROKEN}->{$e->job_id}++;

    push @{$e->facet_data->{errors} //= []} => {details => $message, fail => 1};

    return $e;
}

sub finish {
    my $self = shift;

    my $final_data = {pass => 1};

    while (my ($job_id, $watchers) = each %{$self->{+WATCHERS}}) {
        my $file = $self->{+QUEUED}->{$job_id}->{file};

        if (@$watchers) {
            push @{$final_data->{failed}} => [$job_id, $file] if $watchers->[-1]->fail;
            push @{$final_data->{retried}} => [$job_id, @$watchers - 1, $file, $watchers->[-1]->pass ? 'YES' : 'NO'] if @$watchers > 1;
        }
        else {
            push @{$final_data->{unseen}} => [$job_id, $self->{+QUEUED}->{$job_id}->{file}];
        }
    }

    $final_data->{pass} = 0 if $final_data->{failed} or $final_data->{unseen};

    $self->{+ACTION}->(undef);
    $self->{+ACTION}->($final_data);
}

1;
