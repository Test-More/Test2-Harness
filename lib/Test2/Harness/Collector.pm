package Test2::Harness::Collector;
use strict;
use warnings;

our $VERSION = '1.000038';

use Carp qw/croak/;

use Test2::Harness::Collector::JobDir;

use Test2::Harness::Util::UUID qw/gen_uuid/;
use Test2::Harness::Util::Queue;
use Time::HiRes qw/sleep time/;
use File::Spec;

use File::Path qw/remove_tree/;

use Test2::Harness::Util::HashBase qw{
    <run
    <workdir
    <run_id
    <show_runner_output
    <settings
    <run_dir
    <runner_pid +runner_exited

    +runner_stdout +runner_stderr +runner_aux_dir +runner_aux_handles

    +task_file +task_queue +tasks_done +tasks
    +jobs_file +jobs_queue +jobs_done  +jobs
    +pending

    <wait_time
    <action
};

sub init {
    my $self = shift;

    croak "'run' is required"
        unless $self->{+RUN};

    my $run_dir = File::Spec->catdir($self->{+WORKDIR}, $self->{+RUN_ID});
    die "Could not find run dir" unless -d $run_dir;
    $self->{+RUN_DIR} = $run_dir;

    $self->{+WAIT_TIME} //= 0.02;

    $self->{+ACTION}->($self->_harness_event(0, undef, time, harness_run => $self->{+RUN}, harness_settings => $self->settings, about => {no_display => 1}));
}

sub process {
    my $self = shift;

    while (1) {
        my $count = 0;
        $count += $self->process_runner_output if $self->{+SHOW_RUNNER_OUTPUT};
        $count += $self->process_tasks();

        my $jobs = $self->jobs;

        unless (keys %$jobs) {
            last if $self->{+JOBS_DONE};
            last if $self->runner_done;
        }

        while(my ($job_try, $jdir) = each %$jobs) {
            my $e_count = 0;
            for my $event ($jdir->poll(1000)) {
                $self->{+ACTION}->($event);
                $count++;
            }

            $count += $e_count;
            next if $e_count;
            my $done = $jdir->done or next;

            delete $jobs->{$job_try};
            unless ($self->settings->debug->keep_dirs) {
                my $job_path = $jdir->job_root;
                # Needed because we set the perms so that a tmpdir under it can be used.
                # This is the only remove_tree that needs it because it is the
                # only one in a process that did not initially create the dir.
                chmod(0700, $job_path);
                remove_tree($job_path, {safe => 1, keep_root => 0});
            }

            delete $self->{+PENDING}->{$jdir->job_id} unless $done->{retry};
        }

        last if !$count && $self->runner_exited;
        sleep $self->{+WAIT_TIME} unless $count;
    }

    # One last slurp
    $self->process_runner_output if $self->{+SHOW_RUNNER_OUTPUT};

    $self->{+ACTION}->(undef) if $self->{+JOBS_DONE} && $self->{+TASKS_DONE};

    remove_tree($self->{+RUN_DIR}, {safe => 1, keep_root => 0}) unless $self->settings->debug->keep_dirs;

    return;
}

sub runner_done {
    my $self = shift;

    return 0 if keys %{$self->{+PENDING}};
    return 1;
}

sub runner_exited {
    my $self = shift;
    my $pid = $self->{+RUNNER_PID} or return undef;

    return $self->{+RUNNER_EXITED} if $self->{+RUNNER_EXITED};

    return 0 if kill(0, $pid);

    return $self->{+RUNNER_EXITED} = 1;
}

sub process_runner_output {
    my $self = shift;

    my $out = 0;
    return $out unless $self->{+SHOW_RUNNER_OUTPUT};

    my $stdout = $self->{+RUNNER_STDOUT} //= Test2::Harness::Util::File::Stream->new(
        name => File::Spec->catfile($self->{+WORKDIR}, 'output.log'),
    );

    for my $line ($stdout->poll()) {
        chomp($line);
        my $e = $self->_harness_event(0, undef, time, info => [{details => $line, tag => 'INTERNAL', important => 1}]);
        $self->{+ACTION}->($e);
        $out++;
    }

    my $stderr = $self->{+RUNNER_STDERR} //= Test2::Harness::Util::File::Stream->new(
        name => File::Spec->catfile($self->{+WORKDIR}, 'error.log'),
    );

    for my $line ($stderr->poll()) {
        chomp($line);
        my $e = $self->_harness_event(0, undef, time, info => [{details => $line, tag => 'INTERNAL', debug => 1, important => 1}]);
        $self->{+ACTION}->($e);
        $out++;
    }

    my $auxdir = $self->{+RUNNER_AUX_DIR} //= File::Spec->catdir($self->{+WORKDIR}, 'aux_logs');
    return $out unless -d $auxdir;

    opendir(my $dh, $auxdir) or die "Could not open aux_logs dir: $!";
    for my $path (readdir($dh)) {
        next if $path =~ m/^\.+$/;
        next if $self->{+RUNNER_AUX_HANDLES}->{$path};

        my $tag = uc($path);
        next unless $tag =~ s/\.LOG$//;

        my $debug = 0;
        if ($tag =~ s/\W*(STDERR|STDOUT)\W*//g) {
            $debug = 1 if $1 && uc($1) eq 'STDERR';
        }

        $self->{+RUNNER_AUX_HANDLES}->{$path} = {
            tag    => $tag,
            debug  => $debug,
            stream => Test2::Harness::Util::File::Stream->new(name => File::Spec->catfile($auxdir, $path)),
        };
    }

    for my $file (sort keys %{$self->{+RUNNER_AUX_HANDLES}}) {
        my $data   = $self->{+RUNNER_AUX_HANDLES}->{$file};
        my $stream = $data->{stream};

        for my $line ($stream->poll()) {
            chomp($line);
            my $e = $self->_harness_event(0, undef, time, info => [{details => $line, tag => $data->{tag}, debug => $data->{debug}, important => 1}]);
            $self->{+ACTION}->($e);
            $out++;
        }
    }

    return $out;
}

sub process_tasks {
    my $self = shift;

    return 0 if $self->{+TASKS_DONE};

    my $queue = $self->tasks_queue or return 0;

    my $count = 0;
    for my $item ($queue->poll) {
        $count++;
        my ($spos, $epos, $task) = @$item;

        unless ($task) {
            $self->{+TASKS_DONE} = 1;
            last;
        }

        my $job_id = $task->{job_id} or die "No job id!";
        $self->{+TASKS}->{$job_id} = $task;
        $self->{+PENDING}->{$job_id} = 1 + ($task->{retry} || $self->run->retry || 0);

        my $e = $self->_harness_event($job_id, $task->{is_try} // 0, $task->{stamp}, 'harness_job_queued' => $task);
        $self->{+ACTION}->($e);
    }

    return $count;
}

sub jobs {
    my $self = shift;

    my $jobs = $self->{+JOBS} //= {};

    return $jobs if $self->{+JOBS_DONE};

    my $queue = $self->jobs_queue or return $jobs;

    for my $item ($queue->poll) {
        my ($spos, $epos, $job) = @$item;

        unless ($job) {
            $self->{+JOBS_DONE} = 1;
            last;
        }

        my $job_id = $job->{job_id} or die "No job id!";

        die "Found job without a task!" unless $self->{+TASKS}->{$job_id};

        $self->{+PENDING}->{$job_id}--;
        delete $self->{+PENDING}->{$job_id} if $self->{+PENDING}->{$job_id} < 1;

        my $file = $job->{file};
        my $e = $self->_harness_event(
            $job_id,
            $job->{is_try},
            $job->{stamp},
            harness_job        => $job,
            harness_job_start  => {
                details => "Job $job_id started at $job->{stamp}",
                job_id  => $job_id,
                stamp   => $job->{stamp},
                file    => $file,
                rel_file => File::Spec->abs2rel($file),
                abs_file => File::Spec->rel2abs($file),
            },
            harness_job_launch => {
                stamp => $job->{stamp},
                retry => $job->{is_try},
            },
        );

        $self->{+ACTION}->($e);

        my $job_try = $job_id . '+' . $job->{is_try};

        $jobs->{$job_try} = Test2::Harness::Collector::JobDir->new(
            job_try    => $job->{is_try} // 0,
            job_id     => $job_id,
            run_id     => $self->{+RUN_ID},
            runner_pid => $self->{+RUNNER_PID},
            job_root   => File::Spec->catdir($self->{+RUN_DIR}, $job_try),
        );
    }

    return $jobs;
}

sub _harness_event {
    my $self = shift;
    my ($job_id, $job_try, $stamp, %args) = @_;

    croak "Job id is required" unless defined $job_id;
    croak "Stamp is required" unless defined $stamp;

    return Test2::Harness::Event->new(
        stamp      => $stamp,
        job_id     => $job_id,
        job_try    => $job_try,
        event_id   => gen_uuid(),
        run_id     => $self->{+RUN_ID},
        facet_data => \%args,
    );
}

sub jobs_queue {
    my $self = shift;

    return $self->{+JOBS_QUEUE} if $self->{+JOBS_QUEUE};

    my $jobs_file = $self->{+JOBS_FILE} //= File::Spec->catfile($self->{+RUN_DIR}, 'jobs.jsonl');

    return unless -f $jobs_file;

    return $self->{+JOBS_QUEUE} = Test2::Harness::Util::Queue->new(file => $jobs_file);
}

sub tasks_queue {
    my $self = shift;

    return $self->{+TASK_QUEUE} if $self->{+TASK_QUEUE};

    my $tasks_file = $self->{+TASK_FILE} //= File::Spec->catfile($self->{+RUN_DIR}, 'queue.jsonl');

    return unless -f $tasks_file;

    return $self->{+TASK_QUEUE} = Test2::Harness::Util::Queue->new(file => $tasks_file);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Collector - Module that collects test output and provides it as
an event stream.

=head1 DESCRIPTION

This module is responsible for reading and parsing the output produced by
multiple jobs running under yath.

This module is not intended for external use, it is an implementation detail
and can change at any time. Currently instances of this module are not passed
to any plugins or callbacks.

If you need a collector for a third-party command you should look at
L<App::Yath::Command::collector>. When a command needs a collector (such as
L<App::Yath::Command::test> does) it normally spawns a collector process by
execuing C<yath collector>. The C<start_collector()> subroutine in
L<App::Yath::Command::test> is a good place to look for more details.

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
