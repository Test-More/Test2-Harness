package Test2::Harness::Run::Runner;
use strict;
use warnings;

our $VERSION = '0.001016';

use Carp qw/croak/;
use POSIX ":sys_wait_h";
use Config qw/%Config/;
use IPC::Open3 qw/open3/;
use List::Util qw/none sum first/;
use Time::HiRes qw/sleep time/;
use Test2::Util qw/pkg_to_file/;

use App::Yath::Util qw/find_yath/;
use Test2::Harness::Util qw/open_file write_file_atomic local_env/;

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
    -run_file

    -err_log -out_log
    -_exit
    -pid
    -remote

    -wait_time

    -_next

    -job_runner_class

    -job_count

    -jobs_file  -jobs
    -queue_file -queue
    -state_file -state
    -ready_file
    -hup
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

    $self->{+WAIT_TIME} = 0.02 unless defined $self->{+WAIT_TIME};

    $self->{+JOB_RUNNER_CLASS} ||= 'Test2::Harness::Job::Runner';

    $self->{+ERR_LOG}   = File::Spec->catfile($dir, 'error.log');
    $self->{+OUT_LOG}   = File::Spec->catfile($dir, 'output.log');

    $self->{+READY_FILE} = File::Spec->catfile($dir, 'ready');

    $self->{+STATE_FILE} = File::Spec->catfile($dir, 'state.json');

    $self->{+JOBS_FILE} = File::Spec->catfile($dir, 'jobs.jsonl');
    $self->{+JOBS} = Test2::Harness::Util::File::JSONL->new(name => $self->{+JOBS_FILE});
    $self->{+JOBS}->open_file('>>'); # Touch the file

    $self->{+QUEUE_FILE} = File::Spec->catfile($dir, 'queue.jsonl');
    $self->{+QUEUE} = Test2::Harness::Run::Queue->new(file => $self->{+QUEUE_FILE});

    if ($self->{+RUN}->job_count < 2) {
        $self->{+_NEXT} = 'next_by_stamp';
    }
    elsif ($self->{+RUN}->finite) {
        $self->{+_NEXT} = 'next_finite';
    }
    else {
        $self->{+_NEXT} = 'next_fair';
    }

    $self->{+DIR} = $dir;
}

sub ready {
    my $self = shift;
    return -f $self->{+READY_FILE};
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

    my $class = ref($self);

    my $script = find_yath();
    my $inc    = $self->find_inc;

    return (
        $^X,
        "-I$inc",
        $script,
        'spawn',
        $class,
        $self->{+DIR},
        @_,
    );
}

sub spawn {
    my $self = shift;
    my %params = @_;

    my $run = $self->{+RUN};

    my $rf = Test2::Harness::Util::File::JSON->new(name => $self->{+RUN_FILE});
    $rf->write($run->TO_JSON);

    my $err_log = open_file($self->{+ERR_LOG}, '>');
    my $out_log = open_file($self->{+OUT_LOG}, '>');

    my $env = $run->env_vars;

    my $pid;
    local_env $env => sub {
        $pid = open3(
            undef, ">&" . fileno($out_log), ">&" . fileno($err_log),
            $self->cmd(%params),
        );
    };

    $self->{+PID} = $pid;

    return $pid;
}

sub wait {
    my $self = shift;
    my ($flags) = @_;

    return if defined $self->{+_EXIT};

    local $?;

    my $pid = $self->{+PID} or croak "No PID, cannot wait";
    my $check = waitpid($pid, $flags || 0);
    my $exit = ($? >> 8) || $? & 127;

    return if $check == 0;
    die "Spawn process was already reaped" if $check == -1;

    $self->{+_EXIT} = $exit;

    return;
}

sub exited {
    my $self = shift;

    return 1 if defined $self->exit;
    return 0 unless $self->{+REMOTE};

    croak "No PID to check" unless $self->{+PID};

    return !kill(0, $self->{+PID});
}

sub exit {
    my $self = shift;

    return undef if $self->{+REMOTE};

    return $self->{+_EXIT} if defined $self->{+_EXIT};

    $self->wait(WNOHANG);

    return $self->{+_EXIT};
}

sub preload {
    my $self = shift;

    my $run = $self->{+RUN};
    my $req = $run->preload or return;

    local @INC = ($run->all_libs, @INC);

    my $env = $run->env_vars;

    local_env $env => sub {
        require Test2::API;
        Test2::API::test2_start_preload();

        $self->_preload($req);
    };
}

sub _preload {
    my $self = shift;
    my ($req, $block, $require) = @_;

    $block ||= {};
    $require ||= sub { require $_[0] };

    if ($req) {
        for my $mod (@$req) {
            next if $block->{$mod};
            my $file = pkg_to_file($mod);
            $require->($file);

            next unless $mod->isa('Test2::Harness::Preload');
            $mod->preload($block, job_count => $self->{+JOB_COUNT});
        }
    }
}

sub start {
    my $self = shift;

    my $run = $self->{+RUN};

    my $pidfile = File::Spec->catfile($self->{+DIR}, 'PID');
    write_file_atomic($pidfile, "$$");

    my $sig;
    my $handle_sig = sub {
        my ($got_sig) = @_;

        # Already being handled
        return if $sig;

        $sig = $got_sig;

        die "Runner cought SIG$sig, Attempting to shut down cleanly...\n";
    };

    local $SIG{INT}  = sub { $handle_sig->('INT') };
    local $SIG{TERM} = sub { $handle_sig->('TERM') };
    local $SIG{HUP}  = sub {
        print STDERR "Runner cought SIGHUP, saving state and reloading...\n";
        $self->{+HUP} = 1;
    };

    my $env = $run->env_vars;

    my ($out, $ok, $err);
    local_env $env => sub {
        $self->init_state;

        $self->preload;

        write_file_atomic($self->{+READY_FILE}, "1");

        $ok = eval { $out = $self->_start(@_); 1 };
        $err = $@;
    };

    unless($ok) {
        warn $err;
        eval { $self->kill_jobs($sig || 'TERM'); 1 } or warn $@;
    }

    unless(eval { while(1) { $self->wait_job() or last }; 1 }) {
        warn $@;
        $ok = 0;
    }

    return $out if $ok && defined($out);

    $self->write_remaining_exits();

    return undef if $ok;

    CORE::exit($SIG ? 0 : 255);
}

sub init_state {
    my $self = shift;

    if (-f $self->{+STATE_FILE}) {
        $self->{+STATE} = Test2::Harness::Util::File::JSON->new(name => $self->{+STATE_FILE})->read;
    }
    else {
        $self->{+STATE} = {
            running  => {long => {}, medium => {}, general => {}, isolation => {}},
            pending  => {long => [], medium => [], general => [], isolation => []},
            position => 0,
        };
    }
}

sub _start {
    my $self = shift;

    my $run   = $self->{+RUN};
    my $queue = $self->{+QUEUE};

    my $state = $self->{+STATE};
    $queue->seek($state->{position});

    while (1) {
        $self->wait_jobs();
        $self->respawn if $self->hup; # do not use {+HUP}, this is a hook point

        my $task = $self->next or last;
        next unless ref($task);

        my $runfile = $self->run_job($task);
        return $runfile if $runfile;
    }

    return undef;
}

sub respawn {
    my $self = shift;

    print STDERR "Waiting for currently running jobs to complete before reloading...\n";
    while(1) { $self->wait_job() or last }

    my $state = $self->{+STATE};

    Test2::Harness::Util::File::JSON->new(name => $self->{+STATE_FILE})->write($state);

    exec($self->cmd);
    warn "Should not get here, respawn failed";
    CORE::exit(255);
}

sub wait_jobs {
    my $self = shift;

    local $?;

    my $out = 0;

    my $running = $self->{+STATE}->{running};
    for my $cat (values %$running) {
        for my $pid (keys %$cat) {
            my $got = waitpid($pid, WNOHANG);
            my $ret = $?;
            next if $got == 0;

            my $exit_file = delete $cat->{$pid};
            $out++;

            if ($got == -1) {
                write_file_atomic($exit_file, '-1');
                next;
            }

            if ($got == $pid) {
                write_file_atomic($exit_file, $ret);
                next;
            }

            die "Unexpected return from waitpid($pid): $got";
            # The die should make this unreachable.. but just in case.
            CORE::exit(255);
        }
    }

    return $out;
}

sub wait_job {
    my $self = shift;

    local $?;

    my $running = $self->{+STATE}->{running};

    # Nothing to wait for.
    my $pid = CORE::wait();
    my $ret = $?;

    return 0 if $pid == -1;

    for my $cat (values %$running) {
        my $exit_file = delete $cat->{$pid} or next;

        write_file_atomic($exit_file, $ret);

        return $pid;
    }

    die "Child process $pid was reaped, but was not found in the internal list of running processes";

    # The die should make this unreachable.. but just in case.
    CORE::exit(255);
}

sub kill_jobs {
    my $self = shift;
    my ($sig) = @_;

    my $running = $self->{+STATE}->{running};
    for my $cat (values %$running) {
        for my $pid (keys %$cat) {
            kill($sig, $pid) or warn "Could not kill pid $pid";
        }
    }

    return;
}

sub run_job {
    my $self = shift;
    my ($task) = @_;

    my $job_id = $task->{job_id};
    my $file = $task->{file};

    unless ($job_id) {
        warn "Task does not have a job ID, skipping";
        next;
    }

    unless ($file) {
        warn "Task does not have a file, skipping";
        next;
    }

    my $run = $self->{+RUN};

    my $dir = File::Spec->catdir($self->{+DIR}, $job_id);
    mkdir($dir) or die "Could not create job directory '$dir': $!";
    my $tmp = File::Spec->catdir($dir, 'tmp');
    mkdir($tmp) or die "Coult not create job temp directory '$tmp': $!";

    my $start_file = File::Spec->catfile($dir, 'start');
    my $exit_file  = File::Spec->catfile($dir, 'exit');
    my $file_file  = File::Spec->catfile($dir, 'file');

    write_file_atomic($file_file, $file);
    write_file_atomic($start_file, time());

    my @libs = $run->all_libs;
    push @libs => @{$task->{libs}} if $task->{libs};
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

    my $load   = [@{$run->load || []},        @{$task->{load}        || []}];
    my $loadim = [@{$run->load_import || []}, @{$task->{load_import} || []}];

    my $job = Test2::Harness::Job->new(
        # These can be overriden by the task
        times => $run->times,

        %$task,

        # These win out over task data, most are merged with task data here
        # or above.
        load        => $load,
        load_import => $loadim,
        use_stream  => $stream,
        use_fork    => $fork,
        use_timeout => $timeout,
        job_id      => $job_id,
        file        => $file,
        env_vars    => $env,
        libs        => \@libs,
        switches    => [@{$run->switches}, @{$task->{switches} || []}],
        args        => [@{$run->args}, @{$task->{args} || []}],

        input => $task->{input} || $run->input,

        event_timeout    => $task->{event_timeout},
        postexit_timeout => $task->{postexit_timeout},

        # This should only come from run
        preload => [grep { $_->isa('Test2::Harness::Preload') } @{$run->preload || []}],
    );

    my $via = $task->{via} || ($fork ? ['Fork', 'Open3'] : ['Open3']);

    my $runner = $self->{+JOB_RUNNER_CLASS}->new(
        job => $job,
        dir => $dir,
        via => $via,
    );

    my ($pid, $runfile) = $runner->run;
    return $runfile if $runfile; # In child process

    # In parent
    my $category = $task->{category};
    $category = 'general' unless $category && $self->{+STATE}->{running}->{$category};

    $self->{+JOBS}->write({ %{$job->TO_JSON}, pid => $pid });
    $self->{+STATE}->{running}->{$category}->{$pid} = $exit_file;

    return;
}

sub next {
    my $self = shift;

    my $state = $self->{+STATE};

    return if $state->{ended} && !$self->pending;

    my $wait_time = $self->wait_time;
    my $max = $self->{+RUN}->job_count;
    my $meth = $self->{+_NEXT};

    while(1) {
        $self->wait_jobs();
        return -1 if $self->hup;

        $self->poll_jobs();

        return if $state->{ended} && !$self->pending;

        # Do not get next if we are at/over capacity, or have an isolated test running
        my $running = $self->running;
        if ($max > $running && !keys %{$state->{running}->{isolation}}) {
            my $next = $self->$meth($running, $max);
            return $next if $next;

            sleep($wait_time) if $wait_time;
        }
        else {
            $self->wait_job;
        }
    }
}

sub running {
    my $self = shift;
    my $state = $self->{+STATE};
    return sum(map { scalar(keys %{$_}) } values %{$state->{running}});
}

sub write_remaining_exits {
    my $self = shift;
    my $state = $self->{+STATE};
    my $running = $state->{running};

    for my $cat (keys %$running) {
        my $pids = $running->{$cat};
        for my $pid (keys %$pids) {
            my $exit_file = $pids->{$pid};
            print STDERR "Found un-reaped '$cat' PID $pid, writing an exit file\n";
            write_file_atomic($exit_file, '-1');
        }
    }
}

sub pending {
    my $self = shift;
    my $state = $self->{+STATE};
    return sum(map { scalar(@{$_}) } values %{$state->{pending}});
}

sub _cats_by_stamp {
    my $self = shift;
    my $state = $self->{+STATE};
    my $pending = $state->{pending};
    return sort { $pending->{$a}->[0]->{stamp} <=> $pending->{$b}->[0]->{stamp} } grep { @{$pending->{$_}} } keys %$pending;
}

sub next_by_stamp {
    my $self = shift;
    my ($cat) = $self->_cats_by_stamp;
    return unless $cat;
    return shift(@{$self->{+STATE}->{pending}->{$cat}});
}

sub next_finite {
    my $self = shift;
    my ($running, $max) = @_;

    my $state = $self->{+STATE};

    my $p_gen = $state->{pending}->{general};
    my $p_med = $state->{pending}->{medium};
    my $p_lng = $state->{pending}->{long};
    my $p_iso = $state->{pending}->{iso};

    # If we have more than 1 slot available prefer a longer job
    if ($running < $max - 1) {
        return shift @$p_lng if @$p_lng;
        return shift @$p_med if @$p_med;
    }

    # Fallback with shortest first
    return shift @$p_gen if @$p_gen;
    return shift @$p_lng if @$p_lng;
    return shift @$p_med if @$p_med;

    # Next comes isolation, so we cannot pick one if anything is running.
    return if $running;

    return shift @$p_iso;
}

sub next_fair {
    my $self = shift;
    my ($running, $max) = @_;

    my @cats = $self->_cats_by_stamp;
    return unless @cats;

    my $state = $self->{+STATE};

    my $r_lng = $state->{running}->{long};
    my $r_med = $state->{running}->{medium};

    my $lmrun = sum(scalar(keys(%$r_lng)), scalar(keys(%$r_med))) || 0;
    my $lmmax = $max - 1;

    # Do not fill all slots with 'long' or 'medium' jobs
    shift @cats while @cats > 1    # Do not change if this is the only category
        && ($cats[-1] eq 'long' || $cats[-1] eq 'medium')    # Only change if long/medium
        && $lmrun >= $lmmax;                                 # Only change if the sum of running long+medium is more than max - 1

    my ($cat) = @cats;

    # Next one up requires isolation :-(
    if ($cat eq 'iso') {
        my $p_gen = $state->{pending}->{general};
        my $p_iso = $state->{pending}->{iso};

        # If we have something long running then go ahead and start general tasks, but nothing longer
        return shift @$p_gen if keys %{$state->{running}->{long}} && @$p_gen;

        # Cannot run the iso yet
        return if $running;

        # Now run the iso
        return shift @$p_iso;
    }

    # Return the next item by time recieved
    return shift @{$state->{pending}->{$cat}};
}

sub poll_jobs {
    my $self = shift;
    my $queue = $self->{+QUEUE};

    my $state = $self->{+STATE};
    my $p = $state->{pending};

    for my $item ($queue->poll) {
        my ($spos, $epos, $task) = @$item;

        $state->{position} = $epos;

        if (!$task) {
            $state->{ended} = 1;
            next;
        }

        my $cat = $task->{category};
        $cat = 'general' unless $cat && $self->{+STATE}->{running}->{$cat};

        push @{$p->{$cat}} => $task;
    }

    return;
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
