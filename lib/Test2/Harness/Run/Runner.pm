package Test2::Harness::Run::Runner;
use strict;
use warnings;

our $VERSION = '0.001077';

use Carp qw/croak confess/;
use POSIX ":sys_wait_h";
use Config qw/%Config/;
use List::Util qw/none/;
use Time::HiRes qw/time/;
use Test2::Util qw/pkg_to_file IS_WIN32/;

use Test2::Harness::Util qw/open_file write_file_atomic local_env/;
use Test2::Harness::Util::IPC qw/run_cmd/;

use Test2::Harness::Run();
use Test2::Harness::Run::Queue();
use Test2::Harness::Run::Runner::ProcMan();

use Test2::Harness::Job();
use Test2::Harness::Job::Runner();

use Test2::Harness::Util::File::JSON();

use File::Spec();

use Test2::Harness::Util::HashBase qw{
    -dir
    -run
    -jobs_todo

    -queue -queue_file

    -run_file -ready_file

    -err_log -out_log

    -_exit -pid -remote
    -signal
    -script

    -wait_time

    -_procman
    -_preload_done

    -staged -stages -fork_stages

    -initialized_preloads
};

sub job_runner_class { 'Test2::Harness::Job::Runner' }
sub procman_class    { 'Test2::Harness::Run::Runner::ProcMan' }

sub ready { -f $_[0]->{+READY_FILE} }

sub find_inc {
    # Find out where Test2::Harness::Run::Worker came from, make sure that is in our workers @INC
    my $file = __PACKAGE__;
    $file =~ s{::}{/}g;
    $file .= '.pm';

    my $inc = $INC{$file};
    $inc =~ s{\Q$file\E$}{}g;
    return File::Spec->rel2abs($inc);
}

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

    $self->{+STAGES}      = ['default'];
    $self->{+STAGED}      = [];
    $self->{+FORK_STAGES} = {};

    $self->{+ERR_LOG}    = File::Spec->catfile($dir, 'error.log');
    $self->{+OUT_LOG}    = File::Spec->catfile($dir, 'output.log');
    $self->{+READY_FILE} = File::Spec->catfile($dir, 'ready');
    $self->{+QUEUE_FILE} = File::Spec->catfile($dir, 'queue.jsonl');

    $self->{+QUEUE} ||= Test2::Harness::Run::Queue->new(file => $self->{+QUEUE_FILE});

    $self->{+DIR} = $dir;
}

sub procman {
    my $self = shift;

    my $num = 1;
    return $self->{+_PROCMAN} ||= $self->procman_class->new(
        jobs_file  => File::Spec->catfile($self->{+DIR}, 'jobs.jsonl'),
        run        => $self->{+RUN},
        wait_time  => $self->{+WAIT_TIME},
        stages     => { map {($_ => $num++)} @{$self->{+STAGES}} },
        queue      => $self->{+QUEUE},
        dir        => $self->{+DIR},
        @_,
    );
}

sub cmd {
    my $self = shift;

    my $class = ref($self);

    my $script = $self->{+SCRIPT} or confess "No spawn 'script' specified";
    my $inc = $self->find_inc;

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
        $pid = run_cmd(
            command => [$self->cmd(%params)],
            stdout => $out_log,
            stderr => $err_log,
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
    my $exit = $?;

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

    $self->wait(WNOHANG) unless defined $self->{+_EXIT};

    return $self->{+_EXIT};
}

sub handle_signal {
    my $self = shift;
    my ($sig) = @_;

    return if $self->{+SIGNAL};

    $self->{+SIGNAL} = $sig;

    die "Runner caught SIG$sig. Attempting to shut down cleanly...\n";
}

sub preload {
    my $self = shift;

    $self->{+_PRELOAD_DONE} = 1;

    my $run = $self->{+RUN};
    my $req = $run->preload or return;

    my $env = $run->env_vars;

    local_env $env => sub {
        require Test2::API;
        Test2::API::test2_start_preload();

        $self->_preload($req);
    };
}

sub _preload {
    my $self = shift;
    my ($req, $block, $require_sub) = @_;

    $block ||= {};

    my $stages = $self->{+STAGES} ||= ['default'];
    my $staged = $self->{+STAGED} ||= [];
    my $fork_stages = $self->{+FORK_STAGES} ||= {};

    my %seen = map {($_ => 1)} @$stages;

    my $run = $self->{+RUN};

    if ($req) {
        for my $mod (@$req) {
            next if $block && $block->{$mod};
            my $file = pkg_to_file($mod);

            if ($require_sub) {
                $require_sub->($file);
            }
            else {
                require $file;
            }

            next unless $mod->isa('Test2::Harness::Preload');

            my %args = (
                job_count => $run->job_count,
                finite    => $run->finite,
                jobs_todo => $self->{+JOBS_TODO},
                block     => $block,
            );

            my $imod = $self->_mod_preload($mod, %args);
            push @$staged => $imod;

            $fork_stages->{$_} = 1 for $imod->fork_stages;

            my $idx = 0;
            for my $stage ($imod->stages) {
                unless ($seen{$stage}++) {
                    splice(@$stages, $idx++, 0, $stage);
                    next;
                }

                for (my $i = $idx; $i < @$stages; $i++) {
                    next unless $stages->[$i] eq $stage;
                    $idx = $i + 1;
                    last;
                }
            }
        }
    }
}

sub _mod_preload {
    my $self = shift;
    my ($mod, %args) = @_;

    return $mod->new(%args) if $mod->can('new');

    $mod->preload(%args);
    return $mod;
}

sub set_sig_handlers {
    my $self = shift;

    $SIG{INT}  = sub { $self->handle_signal('INT') };
    $SIG{HUP}  = sub { $self->handle_signal('HUP') };
    $SIG{TERM} = sub { $self->handle_signal('TERM') };
}

sub start {
    my $self = shift;

    my $run = $self->{+RUN};

    my %seen;
    @INC = grep { !$seen{$_}++ } ((map { File::Spec->rel2abs($_) } $run->all_libs), @INC);

    my $pidfile = File::Spec->catfile($self->{+DIR}, 'PID');
    write_file_atomic($pidfile, "$$");

    local $SIG{INT}  = $SIG{INT};
    local $SIG{HUP}  = $SIG{HUP};
    local $SIG{TERM} = $SIG{TERM};
    $self->set_sig_handlers;

    my $env = $run->env_vars;

    my ($out, $ok, $err);
    local_env $env => sub {
        $self->preload;
        $self->procman; # Make sure this si generated now
        write_file_atomic($self->{+READY_FILE}, "1");
        $ok = eval { $out = $self->stage_loop(@_); 1 };
        $err = $@;
        warn $err unless $ok;
    };

    return $out if $ok && defined($out);

    my $procman = $self->procman;

    unless($ok) {
        eval { $procman->kill($self->{+SIGNAL}); 1 } or warn $@;
    }

    unless(eval { $procman->finish; 1 }) {
        warn $@;
        $ok = 0;
    }

    return undef if $ok;

    $procman->write_remaining_exits;

    CORE::exit($self->{+SIGNAL} ? 0 : 255);
}

sub stage_loop {
    my $self = shift;

    for my $stage (@{$self->{+STAGES}}) {
        $self->stage_start($stage) or next;

        my $runfile = $self->task_loop($stage);
        return $runfile if $runfile;

        $self->stage_stop($stage);
    }

    return undef;
}

sub task_loop {
    my $self = shift;
    my ($stage) = @_;

    my $pman = $self->procman;

    while (1) {
        my $task = $pman->next($stage) or return undef;

        my $runfile = $self->run_job($task);
        return $runfile if $runfile;
    }

    return undef;
}

sub stage_should_fork {
    my $self = shift;
    my ($stage) = @_;
    return $self->{+FORK_STAGES}->{$stage} || 0;
}

sub stage_start {
    my $self = shift;
    my ($stage) = @_;

    my $run = $self->{+RUN};

    my $fork = $self->stage_should_fork($stage);

    return 0 if $fork && !$self->stage_fork($stage);

    my $start_meth = "start_stage_$stage";
    for my $mod (@{$self->{+STAGED}}) {
        # Localize these in case something we preload tries to modify them.
        local $SIG{INT}  = $SIG{INT};
        local $SIG{HUP}  = $SIG{HUP};
        local $SIG{TERM} = $SIG{TERM};

        next unless $mod->can($start_meth);
        $mod->$start_meth;
    }

    return 1;
}

sub stage_fork {
    my $self = shift;
    my ($stage) = @_;

    # Must do this before we can fork
    $self->procman->finish;

    my $pid = fork();
    die "Could not fork" unless defined $pid;

    # Child returns true
    unless ($pid) {
        $0 = 'yath-runner-' . $stage;
        return 1;
    }

    # Parent waits for child
    my $check = waitpid($pid, 0);
    my $ret = $?;

    die "waitpid returned $check" unless $check == $pid;
    die "Child process did not exit cleanly: $ret" if $ret;

    return 0;
}

sub stage_stop {
    my $self = shift;
    my ($stage) = @_;

    return unless $self->stage_should_fork($stage);

    $self->procman->finish;

    CORE::exit(0);
}

sub run_job {
    my $self = shift;
    my ($task) = @_;

    my $job_id = $task->{job_id};
    my $file = $task->{file};

    die "Task does not have a job ID" unless $job_id;
    die "Task does not have a file"   unless $file;

    my $run = $self->{+RUN};

    my $dir = File::Spec->catdir($self->{+DIR}, $job_id);
    mkdir($dir) or die "$$ Could not create job directory '$dir': $!";
    my $tmp = File::Spec->catdir($dir, 'tmp');
    mkdir($tmp) or die "Coult not create job temp directory '$tmp': $!";

    my $file_file  = File::Spec->catfile($dir, 'file');
    write_file_atomic($file_file, $file);

    my $start_file = File::Spec->catfile($dir, 'start');
    write_file_atomic($start_file, time());

    my @libs = $run->all_libs;
    push @libs => @{$task->{libs}} if $task->{libs};
    my $env = {
        %{$run->env_vars},
        TMPDIR => $tmp,
        TEMPDIR => $tmp,
        %{$task->{env_vars} || {}},
        PERL_USE_UNSAFE_INC => $task->{unsafe_inc},
        TEST2_JOB_DIR => $dir,
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
        show_times => $run->show_times,

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

        event_uuids => $run->event_uuids,
        mem_usage   => $run->mem_usage,

        input => $task->{input} || $run->input,

        event_timeout    => $task->{event_timeout},
        postexit_timeout => $task->{postexit_timeout},

        # This should only come from run
        preload => [grep { $_->isa('Test2::Harness::Preload') } @{$run->preload || []}],
    );

    my $via = $task->{via} || ($fork ? ['Fork', 'IPC'] : ['IPC']);
    $via = ['Open3'] if IS_WIN32;
    $via = ['Dummy'] if $run->dummy;

    my $job_runner = $self->job_runner_class->new(
        job => $job,
        dir => $dir,
        via => $via,
    );

    my ($pid, $runfile) = $job_runner->run;

    # In child process
    return $runfile if $runfile;

    # In parent
    $self->procman->job_started(task => $task, job => $job, pid => $pid, dir => $dir);

    return undef;
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
