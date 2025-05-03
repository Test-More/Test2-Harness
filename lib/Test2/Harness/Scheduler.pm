package Test2::Harness::Scheduler;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp qw/croak/;
use POSIX qw/:sys_wait_h/;
use List::Util qw/first/;
use Time::HiRes qw/time/;

use Test2::Harness::Scheduler::Run;
use Test2::Harness::IPC::Protocol;
use Test2::Harness::Event;

use Test2::Harness::Util qw/hash_purge/;
use Test2::Harness::IPC::Util qw/ipc_warn/;
use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness::Util::JSON qw/encode_pretty_json/;

use Test2::Harness::Util::HashBase qw{
    +stop
    runner
    single_run

    <resources
    <plugins

    <run_order
    <runs

    <running

    <terminated

    <children

    <run_jobs_added

};

sub stop { $_[0]->{+STOP} = 1 }

sub init {
    my $self = shift;

    croak "'runner' is a required attribute" unless $self->{+RUNNER};

    delete $self->{+TERMINATED};

    $self->{+RUN_ORDER} = [];    # run-id's in order they should be run
    $self->{+RUNS}      = {};
    $self->{+RUNNING}   = {};
    $self->{+CHILDREN}  = {};

    $self->{+RUN_JOBS_ADDED} = {};
}

sub overall_status {
    my $self = shift;

    return {
        title => "Scheduler Status",
        tables => [
            {
                title => "Runs",
                header => ['run_id', 'running jobs', 'total jobs'],
                rows => [map { my $r = $self->{+RUNS}->{$_}; [$_, scalar(keys %{$r->{running}}), scalar(@{$r->{jobs}})] } @{$self->{+RUN_ORDER}}],
            },
            {
                title => "Children",
                format => [qw/duration/, undef, undef, undef],
                header => ['age', 'name', 'type', 'pid'],
                rows => [map { [ time - $_->{stamp}, @{$_}{qw/name type pid/} ] } sort { $a->{name} cmp $b->{name} } values %{$self->{+CHILDREN}}],
            }
        ],
    }
}

sub process_list {
    my $self = shift;

    my @out;

    for my $child (values %{$self->{+CHILDREN} // {}}) {
        push @out => {pid => $child->{pid}, type => $child->{type}, name => $child->{name}, stamp => $child->{stamp}};
    }

    my $jobs = $self->{+RUNNING}->{jobs};
    for my $info (values %$jobs) {
        push @out => {pid => $info->{pid} // 'PENDING', type => 'job', name => $info->{job}->test_file->relative, stamp => $info->{start}};
    }

    return @out;
}

sub terminate {
    my $self = shift;
    my ($reason) = @_;

    $reason ||= 1;

    return $self->{+TERMINATED} ||= $reason;
}

sub start {
    my $self = shift;
    my ($ipc) = @_;
    $self->runner->start($self, $ipc);
}

sub register_child {
    my $self = shift;
    my ($pid, $type, $name, $callback, %params) = @_;

    $self->{+CHILDREN}->{$pid} = {
        %params,
        type     => $type,
        pid      => $pid,
        name     => $name,
        callback => $callback,
        stamp    => time,
    };
}

sub queue_run {
    my $self = shift;
    my ($run) = @_;

    my $run_id = $run->run_id;

    croak "run id '$run_id' already in queue" if $self->{+RUNS}->{$run_id};

    push @{$self->{+RUN_ORDER}} => $run_id;
    $run = $self->{+RUNS}->{$run_id} = Test2::Harness::Scheduler::Run->new(%$run);

    $run->send_initial_events();
    $_->run_queued($run) for @{$self->plugins // []};
    $self->add_jobs_for_run($run);

    return $run_id;
}

sub add_jobs_for_run {
    my $self = shift;
    my ($run) = @_;

    my $run_id = $run->run_id;

    return if $self->{+RUN_JOBS_ADDED}->{$run_id};
    return unless $self->runner->ready;

    for my $job (@{$run->jobs}) {
        $self->job_container($run->todo, $job, vivify => 1)->{$job->{job_id}} = $job;
    }

    $self->{+RUN_JOBS_ADDED}->{$run_id} = 1;
}

sub job_container {
    my $self = shift;
    croak "Insufficient arguments" unless @_;
    $_[0] //= {};
    my ($cont, $job, %params) = @_;

    for my $step ($self->job_fields($job)) {
        return unless exists($cont->{$step}) || $params{vivify};
        $cont = $cont->{$step} //= {};
    }

    return $cont;
}

sub job_fields {
    my $self = shift;
    my ($job) = @_;

    my $tf = $job->test_file;

    my $smoke = $tf->check_feature('smoke') ? 'smoke' : 'main';

    my $stage = $self->runner->job_stage($job, $tf->check_stage) // 'NONE';

    my $cat = $tf->check_category // 'general';
    my $dur = $tf->check_duration // 'medium';

    my $confl = @{$tf->conflicts_list // []} ? 'conflict' : 'none';

    return ($smoke, $stage, $cat, $dur, $confl);
}

sub wait_on_kids {
    my $self = shift;

    local ($?, $!);

    while (1) {
        my $pid = waitpid(-1, WNOHANG);
        my $exit = $?;

        last if $pid < 1;

        my $proc = delete $self->{+CHILDREN}->{$pid} or die "Reaped untracked process!";
        my $cb = $proc->{callback};
        $cb->(pid => $pid, exit => $exit, scheduler => $self) if $cb && ref($cb) eq 'CODE';
    }
}

sub finalize_completed_runs {
    my $self = shift;

    my @run_order;
    for my $run_id (@{$self->{+RUN_ORDER}}) {
        my $run = $self->{+RUNS}->{$run_id} or next;

        my $todo = $run->todo;
        hash_purge($todo);

        my $keep = 0;
        unless ($run->halt) {
            $keep ||= keys %$todo;
            $keep ||= !$self->{+RUN_JOBS_ADDED}->{$run_id};
        }

        $keep ||= keys %{$run->running};

        if ($keep) {
            push @run_order => $run_id;
            next;
        }

        $self->finalize_run($run_id);
    }

    $self->terminate(1) if $self->{+STOP} && !@run_order;

    @{$self->{+RUN_ORDER}} = @run_order;
}

sub finalize_run {
    my $self = shift;
    my ($run_id) = @_;

    my $run = delete $self->{+RUNS}->{$run_id} or return;
    delete $self->{+RUN_JOBS_ADDED}->{$run_id};

    $_->run_complete($run) for @{$self->plugins // []};

    $self->terminate(1) if $self->single_run;

    return if $run->aggregator_use_io;

    return if eval {
        $run->connect->send_message({
            run_complete => {
                run_id => $run_id,
                jobs   => {map { ($_->job_id => $_->results) } @{$run->complete}},
            }
        });

        1;
    };

    ipc_warn(error => $@) unless $@ =~ m/Disconnected pipe/;
}

sub job_update {
    my $self = shift;
    my ($update) = @_;

    my $run_id = $update->{run_id};
    my $job_id = $update->{job_id};

    my $run = $self->{+RUNS}->{$run_id} or die "Invalid run!";
    my $job = $run->job_lookup->{$job_id} or die "Invalid job!";

    if (defined($update->{halt}) && $run->abort_on_bail) {
        $run->set_halt($update->{halt} || 'halted');
        $_->run_halted($run) for @{$self->plugins // []};
    }

    if (my $pid = $update->{pid}) {
        $self->{+RUNNING}->{jobs}->{$job_id}->{pid} = $pid;
    }

    if (my $res = $update->{result}) {
        push @{$job->{results}} => $res;
        my $info = delete $run->running->{$job->job_id};
        $info->{cleanup}->($self) if $info->{cleanup};
    }
}

sub abort {
    my $self = shift;
    my (@runs) = @_;

    my %runs = map { $_ => $self->{+RUNS}->{$_} } @runs ? @runs : keys %{$self->{+RUNS} // {}};

    for my $run (values %runs) {
        $run->set_halt('aborted');
        $_->run_halted($run) for @{$self->plugins // []};
    }

    for my $job (values %{$self->{+RUNNING}->{jobs} // {}}) {
        next unless $runs{$job->{run}->run_id};
        my $pid = $job->{pid} // next;
        CORE::kill('TERM', $pid);
        $job->{killed} = 1;
    }
}

sub kill {
    my $self = shift;
    $self->abort;
}

sub manage_tests {
    my $self = shift;

    for my $job_id (keys %{$self->{+RUNNING}->{jobs}}) {
        my $job_data = $self->{+RUNNING}->{jobs}->{$job_id};

        # Timeout if it takes too long to start
        if (!$job_data->{pid}) {
            my $delta = time - $job_data;
            my $timeout = $self->runner->test_settings->event_timeout || 30;

            if ($delta > $timeout) {
                warn "Job '$job_id' took too long to start, timing it out: " . encode_pretty_json($job_data->{job});
                my $info = delete $job_data->{run}->running->{$job_id};
                $info->{cleanup}->($self) if $info->{cleanup};
            }
        }

        # Kill pid if run is terminated and it has a pid
        if ($job_data->{run}->halt && !$job_data->{killed}) {
            next unless $job_data->{pid};
            CORE::kill('TERM', $job_data->{pid});
            $job_data->{killed} = 1;
        }
    }
}

sub advance {
    my $self = shift;

    $self->finalize_completed_runs;
    $self->wait_on_kids;
    $self->manage_tests;

    return unless $self->runner->ready;

    my ($run, $job, $stage, $cat, $dur, $confl, $job_set, $skip, $resources) = $self->next_job() or return;

    $job->set_running(1);
    my $res_id = $job->resource_id;

    my $ok;
    if ($skip) {
        @$resources = grep { $_->is_job_limiter } @$resources;
        my $env = {};
        $_->assign($res_id, $job, $env) for @$resources;
        $ok = $self->runner->skip_job($run, $job, $env, $skip);
    }
    else {
        my $env = {};
        $env->{T2_HARNESS_JOB_DURATION} = $dur;
        $_->assign($res_id, $job, $env) for @$resources;
        $ok = $self->runner->launch_job($stage, $run, $job, $env);
    }

    # If the job could not be started
    unless ($ok) {
        $_->release($res_id, $job) for @$resources;
        $job->set_running(0);
        $job_set->{$job->job_id} //= $job;
        return 1;
    }

    my $info;
    $info = {
        job => $job,
        run => $run,
        pid     => undef,
        start   => time,
        cleanup => sub {
            my ($scheduler) = @_;

            $_->release($res_id, $job) for @{$resources};

            $scheduler->{+RUNNING}->{categories}->{$cat}--;
            $scheduler->{+RUNNING}->{durations}->{$dur}--;
            $scheduler->{+RUNNING}->{conflicts}->{$_}-- for @{$confl || []};
            $scheduler->{+RUNNING}->{total}--;

            $job->set_running(0);

            my ($res) = reverse(@{$job->{results}});
            unless ($res->{fail} && $res->{retry}) {
                delete $job_set->{$job->job_id};
                push @{$run->complete} => $job;
            }

            # The next several bits are to avoid memory leaks
            my $info1 = delete $run->running->{$job->job_id};
            my $info2 = delete $self->{+RUNNING}->{jobs}->{$job->job_id};
            for my $info ($info1, $info2) {
                next unless $info;
                delete $info->{cleanup};
                delete $info->{job};
            }
            $job = undef;
            $run = undef;
            $resources = undef;

            delete $info->{cleanup};
            $info = undef;
        },
    };

    $run->running->{$job->job_id} = $info;
    $self->{+RUNNING}->{jobs}->{$job->job_id} = $info;

    $self->{+RUNNING}->{categories}->{$cat}++;
    $self->{+RUNNING}->{durations}->{$dur}++;
    $self->{+RUNNING}->{conflicts}->{$_}++ for @{$confl || []};
    $self->{+RUNNING}->{total}++;

    return 1;
}

sub category_order {
    my $self = shift;

    my @cat_order = ('conflicts', 'general');

    my $running = $self->running;

    # Only search immiscible if we have no immiscible running
    # put them first if no others are running so we can churn through them
    # early instead of waiting for them to run 1 at a time at the end.
    unshift @cat_order => 'immiscible' unless $running->{categories}->{immiscible};

    # Only search isolation if nothing is running.
    unshift @cat_order => 'isolation' unless $running->{total};

    return \@cat_order;
}

sub duration_order { [qw/long medium short/] }

sub next_job {
    my $self = shift;

    my $resources = $self->{+RESOURCES};
    my $running   = $self->{+RUNNING};

    my $stages = $self->runner->stage_sets;
    my $cat_order = $self->category_order;
    my $dur_order = $self->duration_order;

    for my $run_id (@{$self->{+RUN_ORDER}}) {
        my $run = $self->{+RUNS}->{$run_id};
        next if $run->halt;

        $self->add_jobs_for_run($run);

        my $search = $run->todo or next;

        for my $smoke (qw/smoke main/) {
            my $search = $search->{$smoke} or next;

            for my $stage_set (@$stages) {
                my ($lstage, $run_by_stage) = @$stage_set;
                my $search = $search->{$lstage} or next;

                for my $cat (@$cat_order) {
                    my $search = $search->{$cat} or next;

                    for my $dur (@$dur_order) {
                        my $search = $search->{$dur} or next;

                        for my $confl (qw/conflict none/) {
                            my $search = $search->{$confl} or next;

                            JOB: for my $job_id (keys %$search) {
                                my $job = $search->{$job_id};
                                next if $job->running;

                                # Skip if conflicting tests are running
                                my $confl = $job->test_file->conflicts_list;
                                next if first { $running->{conflicts}->{$_} } @$confl;

                                my $res_id = $job->resource_id;

                                my $skip;
                                my @use_resources;
                                for my $res (@$resources) {
                                    next unless $res->applicable($res_id, $job);
                                    my $av = $res->available($res_id, $job);

                                    if ($av < 0) {
                                        my $comma = $skip ? 1 : 0;
                                        $skip //= "The following resources are permanently unavailable: ";
                                        $skip .= ', ' if $comma;
                                        $skip .= $res->resource_name;
                                        next;
                                    }

                                    next JOB unless $av || $skip;

                                    push @use_resources => $res;
                                }

                                return ($run, $job, $run_by_stage, $cat, $dur, $confl, $search, $skip, \@use_resources);
                            }
                        }
                    }
                }
            }
        }
    }

    return;
}

sub DESTROY {
    my $self = shift;

    $self->terminate('DESTROY');
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Scheduler - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut


=pod

=cut POD NEEDS AUDIT

