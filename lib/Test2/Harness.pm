package Test2::Harness;
use strict;
use warnings;

our $VERSION = '0.001078';

use Carp qw/croak/;
use List::Util qw/sum/;
use Time::HiRes qw/sleep time/;
use Sys::Hostname qw/hostname/;
use Test2::Harness::Util::JSON qw/encode_canon_json encode_json/;
use Test2::Harness::Util::UUID qw/gen_uuid/;

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
    -jobs_todo
    -job_map
    -event_timeout
    -post_exit_timeout
    -run_id

    -email_from
    -email_owner
    -slack_url
    -slack_fail
    -slack_notify
    -slack_log
    -notify_text
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

    $self->{+JOB_MAP} ||= {};
}

sub run {
    my $self = shift;

    # Do the runs.
    {
        while (1) {
            $self->{+CALLBACK}->() if $self->{+CALLBACK};
            my $complete = $self->{+FEEDER}->complete;
            $self->iteration();
            last if $complete;
            sleep 0.02;
        }
    }

    # Track pass/fail for all our jobs.
    my $seen = 0;
    my (@fail, @pass);
    while (my ($job_id, $watcher) = each %{$self->{+WATCHERS}}) {
        $seen++;
        if ($watcher->fail) {
            push @fail => $watcher->job;
        }
        else {
            push @pass => $watcher->job;
        }
    }

    # Determine what plans didn't finish.
    my $lost;
    if (my $want = $self->{+JOBS_TODO}) {
        $lost = $want - $seen;
    }

    return {
        fail => \@fail,
        pass => \@pass,
        lost => $lost,
    };
}

sub iteration {
    my $self = shift;

    my $live    = $self->{+LIVE};
    my $jobs    = $self->{+JOBS};
    my $job_map = $self->{+JOB_MAP};

    while (1) {
        my @events;

        # Track active watchers in a second hash, this avoids looping over all
        # watchers each iteration.
        foreach my $job_id (sort keys %{$self->{+ACTIVE}}) {
            my $watcher = $self->{+ACTIVE}->{$job_id};
            # Give it up to 5 seconds
            my $killed = $watcher->killed || 0;
            my $done = $watcher->complete || ($killed ? (time - $killed) > 5 : 0) || 0;

            if ($done) {
                $self->{+FEEDER}->job_completed($job_id);
                delete $self->{+ACTIVE}->{$job_id};
            }
            elsif ($self->{+LIVE} && !$killed) {
                push @events => $self->check_timeout($watcher);
            }
        }

        push @events => $self->{+FEEDER}->poll($self->{+BATCH_SIZE});

        last unless @events;

        for my $event (@events) {
            my $job_id = $event->{job_id};

            # Log first, before the watchers transform the events.
            $_->log_raw_event($event) for @{$self->{+LOGGERS}};

            my @delayed;
            if ($job_id) {
                my $job = $job_map->{$job_id} ||= $event->{facet_data}->{harness_job}
                    or die "First event for job ($job_id) was not a job start!";

                if ($jobs) {
                    my $see = $jobs->{$job_id} || $jobs->{$job->{job_name}} || $jobs->{$job->{file}};
                    next unless $see;
                }

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

                # This will transform the events, possibly by adding facets,
                # any return items are new events it produced.
                @delayed = $watcher->process($event);

                my $f = $event->{facet_data};
                if ($f && $f->{harness_job_end}) {
                    $f->{harness_job_end}->{file} = $watcher->file;
                    $f->{harness_job_end}->{fail} = $watcher->fail ? 1 : 0;

                    my $plan = $watcher->plan;
                    $f->{harness_job_end}->{skip} = $plan->{details} || "No reason given" if $plan && !$plan->{count};

                    push @{$f->{errors}} => $watcher->fail_error_facet_list;

                    $self->send_notices($watcher, $event) if $watcher->fail;

                    $watcher->clear_events();
                }
            }

            for my $re (@delayed, $event) {
                $_->log_processed_event($re) for @{$self->{+LOGGERS}};

                my $rf = $re->{facet_data};
                next if $rf->{harness_watcher}->{no_render};

                # Render it now that the watchers have done their thing.
                $_->render_event($re) for @{$self->{+RENDERERS}};
            }
        }
    }

    return;
}

sub send_notices {
    my $self = shift;
    my ($watcher, $event) = @_;

    return unless $self->{+EMAIL_OWNER} || $self->{+SLACK_FAIL} || $self->{+SLACK_NOTIFY};

    my $file   = $watcher->file;
    my $events = $watcher->events;
    my $log    = "";
    my $pretty = "";
    my $host   = hostname();

    require Test2::Formatter::Test2;
    open(my $fh, '>>', \$pretty) or die "Could not open pretty: $!";
    print $fh <<"    EOT";
Test Failed on $host: $file

    EOT
    my $renderer = Test2::Formatter::Test2->new(io => $fh, verbose => 100);

    for my $e (@$events) {
        $log .= encode_canon_json($e) . "\n";
        $renderer->write($e);
    }
    $log .= encode_canon_json($event) . "\n";
    $renderer->write($event);

    require Test2::Harness::Util::TestFile;
    my $tf = Test2::Harness::Util::TestFile->new(file => $watcher->file);

    $self->send_slack_owners($tf, $log, $pretty);
    $self->send_email_owners($tf, $log, $pretty);
}

sub send_slack_owners {
    my $self = shift;
    my ($tf, $log, $pretty) = @_;

    return unless $self->{+SLACK_URL};

    my @to = $tf->meta('slack');
    push @to => @{$self->{+SLACK_FAIL}} if $self->{+SLACK_FAIL};
    return unless @to;

    require HTTP::Tiny;
    my $ht = HTTP::Tiny->new();

    my @attach = (
        {
            fallback  => 'Test Output',
            pretext   => 'Test Output',
            text      => "```$pretty```",
            mrkdwn_in => ['text'],
        }
    );

    push @attach => {
        fallback => 'Test Event Log',
        pretext  => 'Test Event Log',
        text     => $log,
    } if $self->{+SLACK_LOG};

    my $host = hostname();
    my $file = $tf->file;

    my $text = "Test Failed on $host: $file";
    if (my $append = $self->{+NOTIFY_TEXT}) {
        $text .= "\n$append";
    }

    for my $dest (@to) {
        my $r = $ht->post(
            $self->{+SLACK_URL},
            {
                headers => {'content-type' => 'application/json'},
                content => encode_json(
                    {
                        channel     => $dest,
                        text        => $text,
                        attachments => \@attach
                    }
                ),
            },
        );
        warn "Failed to send slack message to '$dest'" unless $r->{success};
    }
}

sub send_email_owners {
    my $self = shift;
    my ($tf, $log, $body) = @_;

    my @to = $tf->meta('owner');

    my $host    = hostname();
    my $subject = "Test Failure on $host";

    my $mail = Email::Stuffer->to(@to);
    $mail->from($self->{+EMAIL_FROM});
    $mail->subject($subject);

    my $append = $self->{+NOTIFY_TEXT} || "";
    $mail->html_body("<html><body>$append<p><pre>$body</pre></body></html>");

    $mail->attach(
        $log,
        content_type => 'application/x-json-stream',
        filename     => 'log.jsonl',
    );

    eval { $mail->send_or_die; 1 } or warn $@;
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

If you do not want this test to time-out you can turn timeouts off on a
per-test basis by adding the following comment to the top of your test file.

# HARNESS-NO-TIMEOUT

CAUTION: THIS IS ALMOST ALWAYS THE WRONG THING TO DO!
         A test suite can hang forever when you turn timeouts off.
    EOT

    my @info = (
        {
            details   => ucfirst($type) . " timeout after $timeout second(s) for job $job_id: $file\n$msg",
            debug     => 1,
            important => 1,
            tag       => 'TIMEOUT',
        }
    );

    my $event_id = gen_uuid();
    my $event    = Test2::Harness::Event->new(
        job_id     => $job_id,
        run_id     => $self->{+RUN_ID},
        event_id   => $event_id,
        stamp      => time,
        facet_data => {info => \@info, about => {uuid => $event_id}},
    );

    return $event unless $self->{+LIVE};
    my $pid = $watcher->job->pid || 'NA';

    if ($type eq 'post-exit') {
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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
