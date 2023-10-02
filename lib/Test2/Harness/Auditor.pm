package Test2::Harness::Auditor;
use strict;
use warnings;

our $VERSION = '1.000155';

use File::Spec;
use Time::HiRes qw/time/;

use Test2::Harness::Util::UUID qw/gen_uuid/;
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

        # If process_event does not return anything we need to record just this
        # event. If it does return then we want to record what it returns.
        if (my @events = $self->process_event($e)) {
            $self->{+ACTION}->($_) for @events;
        }
        else {
            $self->{+ACTION}->($e);
        }
    }
}

sub process_event {
    my $self = shift;
    my ($e) = @_;

    my $job_id  = $e->job_id;
    my $job_try = $e->job_try // 0;

    # Do nothing for non-job events
    return $e unless $job_id;

    my $f = $e->facet_data;

    if (my $task = $f->{harness_job_queued}) {
        $self->{+WATCHERS}->{$job_id} //= [];
        $self->{+QUEUED}->{$job_id} //= $task;
        return $e;
    }

    my $tries = $self->{+WATCHERS}->{$job_id} or return $self->broken($e, "Never saw queue entry");

    if (my $job = $f->{harness_job}) {
        $tries->[$job_try] = Test2::Harness::Auditor::Watcher->new(job => $job, try => $job_try);
    }

    my $watcher = $tries->[$job_try] or return $self->broken($e, "never saw harness_job facet");

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
        my $file = File::Spec->abs2rel($self->{+QUEUED}->{$job_id}->{file});

        if (@$watchers) {
            push @{$final_data->{failed}} => [$job_id, $file, $watchers->[-1]->failed_subtest_tree] if $watchers->[-1]->fail;
            push @{$final_data->{retried}} => [$job_id, scalar(@$watchers), $file, $watchers->[-1]->pass ? 'YES' : 'NO'] if @$watchers > 1;

            if (my $halt = $watchers->[-1]->halt) {
                push @{$final_data->{halted}} => [$job_id, $file, $halt];
            }
        }
        else {
            push @{$final_data->{unseen}} => [$job_id, $self->{+QUEUED}->{$job_id}->{file}];
        }
    }

    $final_data->{pass} = 0 if $final_data->{failed} or $final_data->{unseen};

    my $e = Test2::Harness::Event->new(
        job_id     => 0,
        stamp      => time,
        event_id   => gen_uuid(),
        run_id     => $self->{+RUN_ID},
        facet_data => {harness_final => $final_data},
    );

    $self->{+ACTION}->($e);
    $self->{+ACTION}->(undef);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Auditor - Auditor that validates test results by processing an
event stream.

=head1 DESCRIPTION

The auditor is responsible for taking a stream of events and determining what
is passing or failing. An L<Test2::Harness::Auditor::Watcher> instance is
created for every job_id seen, and events for each job are passed to the proper
watcher for state management.

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
