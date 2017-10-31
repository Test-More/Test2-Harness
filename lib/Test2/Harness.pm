package Test2::Harness;
use strict;
use warnings;

our $VERSION = '0.001030';

use Carp qw/croak/;
use List::Util qw/sum/;
use Time::HiRes qw/sleep time/;
use Data::Dumper;

use Test2::Harness::Util::Term qw/USE_ANSI_COLOR/;
use Test2::Harness::Util::Debug qw/DEBUG/;

use Test2::Harness::Util::HashBase qw{
    -feeder
    -loggers
    -renderers
    -batch_size
    -callback
    -watchers
    -active
    -live
    -jobs
    -jobs_todo
    -event_timeout
    -post_exit_timeout
    -run_id
};

sub init {
    my $self = shift;

    croak "'run_id' is a required attribute"
        unless $self->{+RUN_ID};

    croak "'feeder' is a required attribute"
        unless $self->{+FEEDER};

    croak "'renderers' is a required attribute"
        unless $self->{+RENDERERS};

    croak "'renderers' must be an array reference'"
        unless ref($self->{+RENDERERS}) eq 'ARRAY';

    $self->{+BATCH_SIZE} ||= 1000;
}

sub run {
    my $self = shift;

    {
        while (1) {
            DEBUG("Harness run loop");
            $self->{+CALLBACK}->() if $self->{+CALLBACK};
            my $complete = $self->{+FEEDER}->complete;
            $self->iteration();
            last if $complete;
            sleep 0.02;
        }
    }

    my(@fail, @pass, $seen);
    while (my ($job_id, $watcher) = each %{$self->{+WATCHERS}}) {
        DEBUG("Harness watcher loop ($job_id)");
        $seen++;
        if ($watcher->fail) {
            push @fail => $watcher->job;
        }
        else {
            push @pass => $watcher->job;
        }
    }

    my $lost;
    if (my $want = $self->{+JOBS_TODO}) {
        $lost = $want - $seen;
    }

    return {
        fail => \@fail,
        pass => \@pass,
        lost => $lost,
    }
}

sub iteration {
    my $self = shift;

    my $live = $self->{+LIVE};
    my $jobs = $self->{+JOBS};

    while (1) {
        DEBUG("Harness iteration loop");
        my @events;

        # Track active watchers in a second hash, this avoids looping over all
        # watchers each iteration.
        while(my ($job_id, $watcher) = each %{$self->{+ACTIVE}}) {
            DEBUG("Harness active watcher loop: $job_id");
        #for my $watcher (values %{$self->{+ACTIVE}}) {
            # Give it up to 5 seconds
            my $killed = $watcher->killed || 0;
            my $done = $watcher->complete || ($killed ? (time - $killed) > 5 : 0) || 0;

            DEBUG("Harness active watcher $job_id - KILLED: $killed, DONE: $done");
            if ($done) {
                $self->{+FEEDER}->job_completed($job_id);
                delete $self->{+ACTIVE}->{$job_id};
            }
            elsif($self->{+LIVE} && !$killed) {
                push @events => $self->check_timeout($watcher);
            }
        }

        push @events => $self->{+FEEDER}->poll($self->{+BATCH_SIZE});

        DEBUG("Harness iteration got events: " . scalar(@events));

        last unless @events;

        for my $event (@events) {
            my $job_id = $event->{job_id};
            next if $jobs && !$jobs->{$job_id};

            # Log first, before the watchers transform the events.
            $_->log_event($event) for @{$self->{+LOGGERS}};

            if ($job_id) {
                my $watcher = $self->{+WATCHERS}->{$job_id};

                unless ($watcher) {
                    my $job = $event->{facet_data}->{harness_job}
                        or die "First event for job ($job_id) was not a job start!";

                    $watcher = Test2::Harness::Watcher->new(
                        nested => 0,
                        job    => $job,
                        live   => $live,
                    );

                    $self->{+WATCHERS}->{$job_id} = $watcher;
                    $self->{+ACTIVE}->{$job_id} = $watcher if $live;
                }

                # This will transform the events, possibly by adding facets
                my $f;
                ($event, $f) = $watcher->process($event);

                next unless $event;

                if ($f && $f->{harness_job_end}) {
                    $f->{harness_job_end}->{file} = $watcher->file;
                    $f->{harness_job_end}->{fail} = $watcher->fail;

                    my $plan = $watcher->plan;
                    $f->{harness_job_end}->{skip} = $plan->{details} || "No reason given" if $plan && !$plan->{count};

                    push @{$f->{info}} => $watcher->fail_info_facet_list;
                }
            }

            # Render it now that the watchers have done their thing.
            $_->render_event($event) for @{$self->{+RENDERERS}};
        }
    }

    return;
}

sub check_timeout {
    my $self = shift;
    my ($watcher) = @_;

    my $stamp = time;

    return unless $watcher->job->use_timeout;
    return if $watcher->killed;

    my $last_poll = $self->{+FEEDER}->job_lookup->{$watcher->job->job_id}->last_poll() or return;
    my $poll_delta = $stamp - $last_poll;

    # If we have not polled recently then we cannot fault the job for having no
    # events.
    return if $poll_delta > 2;

    my $delta = $stamp - $watcher->last_event;

    if (my $timeout = $watcher->job->event_timeout || $self->{+EVENT_TIMEOUT}) {
        return $self->timeout($watcher, 'event', $timeout, <<"        EOT") if $delta >= $timeout;
This happens if a test has not produced any events within a timeout period, but
does not appear to be finished. Usually this happens when a test has frozen.
        EOT
    }

    # Not done if there is no exit
    return unless $watcher->has_exit;

    if (my $timeout = $watcher->job->postexit_timeout || $self->{+POST_EXIT_TIMEOUT}) {
        return $self->timeout($watcher, 'post-exit', $timeout, <<"        EOT") if $delta >= $timeout;
Sometimes a test will fork producing output in the child while the parent is
allowed to exit. In these cases we cannot rely on the original process exit to
tell us when a test is complete. In cases where we have an exit, and partial
output (assertions with no final plan, or a plan that has not been completed)
we wait for a timeout period to see if any additional events come into
existence.
        EOT
    }

    return;
}

sub timeout {
    my $self = shift;
    my ($watcher, $type, $timeout, $msg) = @_;

    my $job_id = $watcher->job->job_id;
    my $file   = $watcher->job->file;

    $msg .= <<"    EOT";

You can turn this off on a per-test basis by adding the comment
# HARNESS-NO-TIMEOUT
to the top of your test file (but below the #! line).
    EOT

    my @info = (
        {
            details   => ucfirst($type) . " timeout after $timeout second(s) for job $job_id: $file\n$msg",
            debug     => 1,
            important => 1,
            tag       => 'TIMEOUT',
        }
    );

    my $event = Test2::Harness::Event->new(
        job_id     => $job_id,
        run_id     => $self->{+RUN_ID},
        event_id   => "timeout-$type-$job_id",
        stamp      => time,
        times      => [times],
        facet_data => {info => \@info},
    );

    return $event unless $self->{+LIVE};
    my $pid = $watcher->job->pid || 'NA';

    if($type eq 'post-exit') {
        $watcher->set_complete(1);
        return;
    }

    push @info => {
        details   => "Killing job: $job_id, PID: $pid",
        debug     => 1,
        important => 1,
        tag       => 'TIMEOUT',
    };

    return $event if $watcher->kill;

    push @info => {
        details   => "Could not kill job $job_id",
        debug     => 1,
        important => 1,
        tag       => 'TIMEOUT',
    };

    return $event;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness - Test2 Harness designed for the Test2 event system

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

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
