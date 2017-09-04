package Test2::Harness::Run::Runner;
use strict;
use warnings;

our $VERSION = '0.001005';

use Carp qw/croak/;
use POSIX ":sys_wait_h";
use Config qw/%Config/;
use IPC::Open3 qw/open3/;
use List::Util qw/none/;
use Time::HiRes qw/sleep time/;
use Test2::Util qw/pkg_to_file/;
use Test2::Harness::Util qw/open_file write_file_atomic/;

use Test2::Harness::Run();
use Test2::Harness::Run::Queue();

use Test2::Harness::Job();
use Test2::Harness::Job::Runner();

use Test2::Harness::Util::File::JSON();
use Test2::Harness::Util::File::JSONL();

use File::Spec();

use Test2::Harness::Util::HashBase qw{
    -dir
    -run
    -run_file -jobs_file

    -general_queue_file
    -long_queue_file
    -isolate_queue_file
    -queue_index_file

    -end_file

    -err_log -out_log
    -_exit
    -pid
    -_procs
};

sub init {
    my $self = shift;

    croak "'dir' is a required attribute" unless $self->{+DIR};

    my $dir = File::Spec->rel2abs($self->{+DIR});

    croak "'$dir' is not a valid directory"
        unless -d $dir;

    my $run_file = $self->{+RUN_FILE} ||= File::Spec->catfile($dir, 'run.json');

    if (!$self->{+RUN} && -f $run_file) {
        my $rf = Test2::Harness::Util::File::JSON->new(name => $run_file);
        $self->{+RUN} = Test2::Harness::Run->new(%{$rf->read()});
    }

    croak "'run' is a required attribute" unless $self->{+RUN};

    $self->{+ERR_LOG}    = File::Spec->catfile($dir, 'error.log');
    $self->{+OUT_LOG}    = File::Spec->catfile($dir, 'output.log');
    $self->{+JOBS_FILE}  = File::Spec->catfile($dir, 'jobs.jsonl');

    $self->{+GENERAL_QUEUE_FILE} = File::Spec->catfile($dir, 'general_queue.jsonl');
    $self->{+ISOLATE_QUEUE_FILE} = File::Spec->catfile($dir, 'isolate_queue.jsonl');
    $self->{+LONG_QUEUE_FILE}    = File::Spec->catfile($dir, 'long_queue.jsonl');
    $self->{+QUEUE_INDEX_FILE}   = File::Spec->catfile($dir, 'queue_index.jsonl');

    $self->{+END_FILE}     = File::Spec->catfile($dir, 'end');

    $self->{+DIR} = $dir;
}

sub ready {
    my $self = shift;

    return 0 unless -e $self->{+GENERAL_QUEUE_FILE};
    return 0 unless -e $self->{+ISOLATE_QUEUE_FILE};
    return 0 unless -e $self->{+LONG_QUEUE_FILE};

    return 1;
}

sub find_spawn_script {
    my $self = shift;

    my $script = $ENV{T2_HARNESS_SPAWN_SCRIPT} || 'yath-spawn';
    return $script if -f $script;

    if ($0 && $0 =~ m{(.*)\byath(-.*)?$}) {
        return "$1$script" if -f "$1$script";
    }

    # Do we have the full path?
    # Load IPC::Cmd only if needed, it indirectly loads version.pm which really
    # screws things up...
    require IPC::Cmd;
    if(my $out = IPC::Cmd::can_run($script)) {
        return $out;
    }

    die "Could not find '$script' in execution path";
}

sub find_inc {
    my $self = shift;

    # Find out where Test2::Harness::Run::Worker came from, make sure that is in our workers @INC
    my $inc = $INC{"Test2/Harness/Run/Runner.pm"};
    $inc =~ s{/Test2/Harness/Run/Runner\.pm$}{}g;
    return File::Spec->rel2abs($inc);
}

sub cmd {
    my $self = shift;

    my $script = $self->find_spawn_script;
    my $inc    = $self->find_inc;

    return (
        $^X,
        "-I$inc",
        $script,
        $self->{+DIR},
    );
}

sub spawn {
    my $self = shift;

    my $run = $self->{+RUN};

    my $rf = Test2::Harness::Util::File::JSON->new(name => $self->{+RUN_FILE});
    $rf->write($run->TO_JSON);

    my $err_log = open_file($self->{+ERR_LOG}, '>');
    my $out_log = open_file($self->{+OUT_LOG}, '>');

    my $env = $run->env_vars;
    local $ENV{$_} = $env->{$_} for keys %$env;

    my $pid = open3(
        undef, ">&" . fileno($out_log), ">&" . fileno($err_log),
        $self->cmd,
    );

    $self->{+PID} = $pid;

    return $pid;
}

sub wait {
    my $self = shift;
    my ($flags) = @_;

    return if defined $self->{+_EXIT};

    my $pid = $self->{+PID} or croak "No PID, cannot wait";
    my $check = waitpid($pid, $flags || 0);
    my $exit = ($? >> 8);

    return if $check == 0;
    die "Spawn process was already reaped" if $check == -1;

    $self->{+_EXIT} = $exit;

    return;
}

sub exit {
    my $self = shift;

    return $self->{+_EXIT} if defined $self->{+_EXIT};

    $self->wait(WNOHANG);

    return $self->{+_EXIT};
}

sub start {
    my $self = shift;

    my $run = $self->{+RUN};

    my $orig = File::Spec->curdir();
    if (my $chdir = $run->chdir) {
        chdir($chdir);
    }

    my $SIG;
    my $handle_sig = sub {
        my ($sig) = @_;

        # Already being handled
        return if $SIG;

        $SIG = $sig;

        die "Runner cought SIG$sig, Attempting to shut down cleanly...\n";
    };

    local $SIG{INT}  = sub { $handle_sig->('INT') };
    local $SIG{TERM} = sub { $handle_sig->('TERM') };

    my $out;
    my $ok = eval { $out = $self->_start(@_); 1 };
    my $err = $@;

    chdir($orig);

    return $out if $ok;

    warn $err;

    for my $proc (@{$self->{+_PROCS} || []}) {
        my ($pid) = @$proc;

        my $sig = $SIG || 'TERM';
        print STDERR "Killing pid ($sig): $pid\n";
        kill($sig, $pid);
        waitpid($pid, WNOHANG);
    }

    CORE::exit($SIG ? $SIG eq 'TERM' ? 143 : $SIG eq 'INT' ? 130 : 255 : 255);
}

sub _start {
    my $self = shift;

    my $run = $self->{+RUN};

    my $pidfile = File::Spec->catfile($self->{+DIR}, 'PID');
    write_file_atomic($pidfile, "$$");

    print "Runner pid: $$\n" if $run->verbose;

    my $env = $run->env_vars;
    $ENV{$_} = $env->{$_} for keys %$env;

    my $jobs_file = Test2::Harness::Util::File::JSONL->new(name => $self->{+JOBS_FILE});

    my $gen_queue  = Test2::Harness::Run::Queue->new(file => $self->{+GENERAL_QUEUE_FILE});
    my $iso_queue  = Test2::Harness::Run::Queue->new(file => $self->{+ISOLATE_QUEUE_FILE});
    my $long_queue = Test2::Harness::Run::Queue->new(file => $self->{+LONG_QUEUE_FILE});

    my (%JOBS, $JOB_ID);
    if (-e $self->{+QUEUE_INDEX_FILE}) {
        my $idx = Test2::Harness::Util::File::JSON->new(name => $self->{+QUEUE_INDEX_FILE});
        my $data = $idx->read;
        %JOBS   = %{$data->{jobs}};
        $JOB_ID = $data->{job_id};
        $gen_queue->seek($data->{gen_queue_pos});
        $long_queue->seek($data->{long_queue_pos});
        $iso_queue->seek($data->{iso_queue_pos});
    }
    else {
        $JOB_ID = 1;
    }

    $self->preload if $run->preload;

    my $max = $run->job_count;

    my %running = (long => 0, gen => 0, iso => 0);
    my %pos     = (long => 0, gen => 0, iso => 0);
    my %queue = (long => [], gen => [], iso => []);

    my @procs;
    $self->{+_PROCS} = \@procs;
    my $reap = sub {
        my @keep;
        for my $proc (@procs) {
            if ($self->_reap_proc($proc)) {
                $running{$proc->[2]}--;
            }
            else {
                push @keep => $proc;
            }
        }
        @procs = @keep;
    };

    my $wait = sub {
        while (1) {
            $reap->();
            last unless @procs;
            sleep 0.02;
        }

        delete $self->{+_PROCS};
    };

    my ($pick, $poll);

    if ($max < 2) {
        $pick = sub { return (shift(@{$queue{gen}}), 'gen') };

        $poll = sub {
            push @{$queue{gen}} => $gen_queue->poll;
            push @{$queue{gen}} => $iso_queue->poll;
            push @{$queue{gen}} => $long_queue->poll;
        };
    }
    else {
        $poll = sub {
            # Add a stamp to each to insure it does eventually get run, even if
            # it is not a completely fair queing
            push @{$queue{gen}}  => map { $_->{stamp} ||= time; $_ } $gen_queue->poll;
            push @{$queue{iso}}  => map { $_->{stamp} ||= time; $_ } $iso_queue->poll;
            push @{$queue{long}} => map { $_->{stamp} ||= time; $_ } $long_queue->poll;
        };

        if ($run->finite) {
            $pick = sub {
                my $long = $running{long};
                my $gen  = $running{gen};
                my $iso  = $running{iso};

                # Do not run anything if an isolation test is running.
                return if $iso;

                # Fill all but one process with long running when we can
                return (shift(@{$queue{long}}), 'long')
                    if $long < ($max - 1) && @{$queue{long}};

                # Fill whats left with general ones
                return (shift(@{$queue{gen}}), 'gen')
                    if $gen;

                # Make sure the long ones actually get run
                return (shift(@{$queue{long}}), 'long')
                    if $long;

                # Run isolation tests last
                return (shift(@{$queue{iso}}), 'iso')
                    if @{$queue{iso}};
            };
        }
        else {
            $pick = sub {
                my $long = $running{long};
                my $gen  = $running{gen};
                my $iso  = $running{iso};

                # Do not run anything if an isolation test is running.
                return if $iso;

                # Grab the item with the oldest stamp fromt he top of each queue.
                my ($name) = sort { $queue{$a}->[0]->{stamp} <=> $queue{$b}->[0]->{stamp} } grep { @{$queue{$_}} } qw/gen iso long/;

                # If the winner is an isolation test we have to wait until anything running completes
                return if $name eq 'iso' && $long || $gen;

                return (shift(@{$queue{$name}}), $name);
            }
        }
    }

    my $HUP = 0;
    local $SIG{HUP} = sub {
        print "Caught SIGHUP...\n";
        print "Waiting for running processes to complete before respawning...\n";
        $HUP++;
    };

    while (1) {
        if ($HUP) {
            $wait->();
            print "Respawning...\n";

            my $idx = Test2::Harness::Util::File::JSON->new(name => $self->{+QUEUE_INDEX_FILE});
            $idx->write(
                {
                    jobs           => \%JOBS,
                    job_id         => $JOB_ID,
                    gen_queue_pos  => $pos{gen},
                    iso_queue_pos  => $pos{iso},
                    long_queue_pos => $pos{long},
                }
            );

            exec($self->cmd);
            warn "Should not get here!";
            CORE::exit(255);
        }

        $poll->();
        $reap->();

        if (@procs >= $max || $running{iso}) {
            sleep 0.01;
            next;
        }

        my ($item, $queue) = $pick->();

        if (!$item) {
            last if -e $self->{+END_FILE}
                && !@{$queue{gen}}
                && !@{$queue{long}}
                && !@{$queue{iso}};

            sleep 1;
            sleep 0.02;
            next;
        }

        $running{$queue}++;
        $pos{$queue} = $item->[1];

        my $task = $item->[-1];

        my $id;
        if ($task->{job_id}) {
            $id = $task->{job_id};
            die "Duplicate job id requested!" if $JOBS{$id}++;
        }
        else {
            $id = $JOB_ID++;
            $JOBS{$id}++;
        }

        my $file = $task->{file} or die "Bad queue item, no file";

        my $dir = File::Spec->catdir($self->{+DIR}, $id);
        mkdir($dir) or die "Could not create job directory '$dir': $!";
        my $tmp = File::Spec->catdir($dir, 'tmp');
        mkdir($tmp) or die "Coult not create job temp directory '$tmp': $!";

        my $start_file = File::Spec->catfile($dir, 'start');
        my $exit_file = File::Spec->catfile($dir, 'exit');
        my $file_file = File::Spec->catfile($dir, 'file');

        write_file_atomic($file_file, $file);
        write_file_atomic($start_file, time());

        my @libs = $run->all_libs;
        unshift @libs => @{$task->{libs}} if $task->{libs};
        my $env = {
            %{$run->env_vars},
            TMPDIR => $tmp,
            TEMPDIR => $tmp,
            %{$task->{env_vars} || {}},
            PERL_USE_UNSAFE_INC => $task->{unsafe_inc},
        };

        my $p5l = join $Config{path_sep} => ($env->{PERL5LIB} || ()), @libs;
        $env->{PERL5LIB} = $p5l;

        # If any are false, then the answer is false.
        my $stream  = none { defined $_ && !$_ } $task->{use_stream},  $run->use_stream,  1;
        my $timeout = none { defined $_ && !$_ } $task->{use_timeout}, $run->use_timeout, 1;
        my $fork    = none { defined $_ && !$_ } $task->{use_fork}, $task->{use_preload}, $run->use_fork, 1;

        my $job = Test2::Harness::Job->new(
            # These can be overriden by the task
            times => $run->times,

            %$task,

            # These win out over task data, most are merged with task data here
            # or above.
            use_stream => $stream,
            use_fork   => $fork,
            timeout    => $timeout,
            job_id     => $id,
            file       => $file,
            env_vars   => $env,
            libs       => \@libs,
            switches   => [@{$run->switches}, @{$task->{switches} || []}],
            args       => [@{$run->args}, @{$task->{args} || []}],
            input => $task->{input} || $run->input,
            chdir => $task->{chdir} || $run->chdir,
        );

        my $runner = Test2::Harness::Job::Runner->new(
            job => $job,
            dir => $dir,
            via => ['Fork', 'Open3'],
        );

        my ($pid, $runfile) = $runner->run;
        return $runfile if $runfile; # In child process

        push @procs => [$pid, $exit_file, $queue];
        $jobs_file->write({ %{$job->TO_JSON}, pid => $pid, queue => $queue });
    }

    $wait->();

    return undef;
}

sub preload {
    my $self = shift;

    my $run = $self->{+RUN};
    my $list = $run->preload;

    local @INC = ($run->all_libs, @INC);

    require Test2::API;
    Test2::API::test2_start_preload();

    for my $mod (@$list) {
        my $file = pkg_to_file($mod);
        require $file;
    }
}

sub _reap_proc {
    my $self = shift;
    my ($proc) = @_;

    local $?;

    my ($pid, $exit_file) = @$proc;

    my $check = waitpid($pid, WNOHANG);
    my $exit = $?;

    return 0 if $check == 0;

    die "'$pid' does not exist" if $check == -1;

    $exit >>= 8;
    write_file_atomic($exit_file, $exit);

    return $pid;
}

sub end_queue {
    my $self = shift;
    write_file_atomic($self->{+END_FILE}, "1");
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Run::Runner - Logic for executing a test run.

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
