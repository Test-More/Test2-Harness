package Test2::Harness;
use strict;
use warnings;

our $VERSION = '0.001001';

use Carp qw/croak/;
use List::Util qw/sum/;
use Time::HiRes qw/sleep time/;

use Test2::Harness::Util::Term qw/USE_ANSI_COLOR/;

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

    while (1) {
        $self->{+CALLBACK}->() if $self->{+CALLBACK};
        my $complete = $self->{+FEEDER}->complete;
        $self->iteration();
        last if $complete;
        sleep 0.02;
    }

    my(@fail, @pass);
    for my $job_id (sort keys %{$self->{+WATCHERS}}) {
        my $watcher = $self->{+WATCHERS}->{$job_id};

        if ($watcher->fail) {
            push @fail => $watcher->job;
        }
        else {
            push @pass => $watcher->job;
        }
    }

    return {
        fail => \@fail,
        pass => \@pass,
    }
}

sub iteration {
    my $self = shift;

    my $live = $self->{+LIVE};
    my $jobs = $self->{+JOBS};

    while (1) {
        my @events;

        # Track active watchers in a second hash, this avoids looping over all
        # watchers each iteration.
        for my $job_id (sort keys %{$self->{+ACTIVE}}) {
            my $watcher = $self->{+ACTIVE}->{$job_id};

            if ($watcher->complete) {
                $self->{+FEEDER}->job_completed($job_id);
                delete $self->{+ACTIVE}->{$job_id};
            }
            elsif($self->{+LIVE}) {
                push @events => $self->check_timeout($watcher);
            }
        }

        push @events => $self->{+FEEDER}->poll($self->{+BATCH_SIZE});
        last unless @events;

        for my $event (@events) {
            my $job_id = $event->job_id;
            next if $jobs && !$jobs->{$job_id};

            # Log first, before the watchers transform the events.
            $_->log_event($event) for @{$self->{+LOGGERS}};

            if ($job_id) {
                # This will transform the events, possibly by adding facets
                my $watcher = $self->{+WATCHERS}->{$job_id};

                unless ($watcher) {
                    my $job = $event->facet_data->{harness_job}
                        or die "First event for job ($job_id) was not a job start!";

                    $watcher = Test2::Harness::Watcher->new(
                        nested            => 0,
                        job               => $job,
                        live              => $live,
                        event_timeout     => $self->{+EVENT_TIMEOUT},
                        post_exit_timeout => $self->{+POST_EXIT_TIMEOUT},
                    );

                    $self->{+WATCHERS}->{$job_id} = $watcher;
                    $self->{+ACTIVE}->{$job_id} = $watcher if $live;
                }

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

    my $delta = $stamp - $watcher->last_event;

    my $timeouts = 0;
    if (my $timeout = $self->{+EVENT_TIMEOUT}) {
        return $self->timeout($watcher, 'event', $timeout, <<"        EOT") if $delta >= $timeout;
This happens if a test has not produced any events within a timeout period, but
does not appear to be finished. Usually this happens when a test has frozen.
        EOT
    }

    # Not done if there is no exit
    return unless $watcher->has_exit;

    if (my $timeout = $self->{+POST_EXIT_TIMEOUT}) {
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
        facet_data => {info => \@info},
    );

    return $event unless $self->{+LIVE};
    my $pid = $watcher->job->pid || 'NA';

    push @info => {
        details   => "Killing job: $job_id, PID: $pid",
        debug     => 1,
        important => 1,
        tag       => 'TIMEOUT',
    } unless $type eq 'post-exit';

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

=back

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
