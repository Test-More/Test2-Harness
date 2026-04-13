package Test2::Harness2::Collector;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use POSIX qw/:sys_wait_h/;
use Time::HiRes qw/time sleep/;
use Scalar::Util qw/blessed/;
use IO::Handle;
use Atomic::Pipe;

use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Event;
use Test2::Harness2::Util qw/mod2file parse_exit/;
use Test2::Harness2::Util::JSON qw/encode_json encode_json_file/;
use Test2::Harness2::Util::HashBase qw{
    <launch
    <env_vars
    <out_fh
    <err_fh
    <child_pid
    <output_file
    <auditor
    <parser
    <renderers
    <parent_pids
    <kill_timeout

    <collector_pid
    <exit_code

    +_started
    <_owns_child
};

use constant IS_WIN32 => $^O eq 'MSWin32';

sub init {
    my $self = shift;

    # Map spec constructor names to internal attribute names so callers can
    # use the natural names from the spec (stdout, stderr, pid, env) even
    # though HashBase cannot use those as constants due to Perl reserved words.
    $self->{+OUT_FH}    //= delete $self->{stdout} if exists $self->{stdout};
    $self->{+ERR_FH}    //= delete $self->{stderr} if exists $self->{stderr};
    $self->{+CHILD_PID} //= delete $self->{pid}    if exists $self->{pid};
    $self->{+ENV_VARS}  //= delete $self->{env}    if exists $self->{env};

    $self->{+KILL_TIMEOUT} //= 15;
    $self->{+RENDERERS}    //= [];
    $self->{+ENV_VARS}     //= {};

    my $has_launch = defined $self->{+LAUNCH};
    my $has_stdio  = defined($self->{+OUT_FH}) || defined($self->{+ERR_FH});

    croak "Must specify either 'launch' or 'stdout'/'stderr', not both"
        if $has_launch && $has_stdio;

    croak "Must specify either 'launch' or 'stdout'/'stderr'"
        unless $has_launch || $has_stdio;

    croak "'output_file' is a required attribute"
        unless defined $self->{+OUTPUT_FILE};

    # Normalize launch to arrayref
    $self->{+LAUNCH} = [$self->{+LAUNCH}] if $has_launch && !ref($self->{+LAUNCH});

    # Open string paths for file-based handle input
    if ($has_stdio) {
        for my $attr (+OUT_FH, +ERR_FH) {
            next unless defined $self->{$attr};
            next if ref $self->{$attr};

            # It's a string path -- open it
            my $path = $self->{$attr};
            open(my $fh, '<', $path) or croak "Could not open '$path': $!";
            $self->{$attr} = $fh;
        }
    }

    # Default parser
    $self->{+PARSER} //= 'Test2::Harness2::Collector::Parser::IOParser';

    # Load parser class if it's a class name
    require(mod2file($self->{+PARSER})) unless ref $self->{+PARSER};
}

sub spawn {
    my ($class, %params) = @_;
    my $self = $class->new(%params);
    $self->start();
    return $self;
}

sub start {
    my $self = shift;

    croak "Collector already started" if $self->{+_STARTED};
    $self->{+_STARTED} = 1;

    $self->_spawn_collector();

    return;
}

sub _spawn_collector {
    my $self = shift;

    return $self->_spawn_collector_win32() if IS_WIN32;

    my $pid = fork() // die "Failed to fork collector: $!";

    # Parent - record the collector pid
    return $self->{+COLLECTOR_PID} = $pid if $pid;

    # Child - run the collector
    unless (eval { $self->_run_collector(); 1 }) {
        warn "Collector process died: $@";
        exit(1);
    }

    exit(0);
}

sub _spawn_collector_win32 {
    my $self = shift;

    my $has_launch = defined $self->{+LAUNCH};

    unless ($has_launch) {
        # Pipe-based and file-based callers pass in file handles which
        # cannot be serialized to a new process, so run the collector inline.
        warn "Collector died: $@" unless eval { $self->_run_collector(); 1 };
        return;
    }

    # Launch mode: serialize the constructor args to a temp JSON file
    # and spawn a new perl process that loads this module and runs
    # the collector loop, same pattern as the old start_collected_process.
    my %params = (
        launch       => $self->{+LAUNCH},
        env_vars     => $self->{+ENV_VARS},
        output_file  => $self->{+OUTPUT_FILE},
        kill_timeout => $self->{+KILL_TIMEOUT},
    );

    $params{parent_pids} = $self->{+PARENT_PIDS} if $self->{+PARENT_PIDS};

    # Parser must be a class name for the spawned process to load it
    my $parser = $self->{+PARSER};
    if (ref $parser) {
        $params{parser} = ref($parser);
    }
    else {
        $params{parser} = $parser;
    }

    my $json_file = encode_json_file(\%params);

    # Build the command: current perl, all @INC paths, load this module,
    # then run the collect_from_file() class method.
    my %seen;
    my @inc = grep { -d $_ && !$seen{$_}++ } @INC;

    my @cmd = (
        $^X,
        (map { "-I$_" } @inc),
        '-mTest2::Harness2::Collector',
        '-e', 'Test2::Harness2::Collector->collect_from_file($ARGV[0])',
        $json_file,
    );

    my $pid;
    my $ok  = eval { $pid = system 1, @cmd; 1 };
    my $err = $@;

    if (!$ok || !$pid || $pid < 0) {
        unlink($json_file);
        croak "Failed to spawn collector process: " . ($err || $!);
    }

    $self->{+COLLECTOR_PID} = $pid;
}

# Class method invoked by the spawned collector process on Windows.
# Reads constructor args from a JSON file, builds a new Collector
# (skipping the spawn step), and runs the collection loop directly.
sub collect_from_file {
    my ($class, $file) = @_;

    require Test2::Harness2::Util::JSON;
    my $params = Test2::Harness2::Util::JSON::decode_json_file($file, unlink => 1);

    my $self = $class->new(%$params);

    unless (eval { $self->_run_collector(); 1 }) {
        warn "Collector process died: $@";
        exit(1);
    }

    exit(0);
}

sub _run_collector {
    my $self = shift;

    my ($child_pid, $out_r, $err_r);
    my $started_child = defined($self->{+LAUNCH}) || $self->{+_OWNS_CHILD};

    if (defined $self->{+LAUNCH}) {
        ($child_pid, $out_r, $err_r) = $self->_launch_child();
        $self->{+CHILD_PID} = $child_pid;
    }
    else {
        $child_pid = $self->{+CHILD_PID};

        # Wrap handles for the collection loop.
        # Pipe handles: wrap in Atomic::Pipe with mixed_data_mode.
        # Regular file handles: use a plain line-reader shim.
        # Fifo/pipe handles passed as file paths: also wrapped in Atomic::Pipe.
        $out_r = $self->_wrap_handle($self->{+OUT_FH}) if defined $self->{+OUT_FH};
        $err_r = $self->_wrap_handle($self->{+ERR_FH}) if defined $self->{+ERR_FH};
    }

    # Set process name
    $self->_set_procname($child_pid);

    # Setup signal handlers
    my $got_signal;
    my $old_term = $SIG{TERM};
    my $old_int  = $SIG{INT};

    $SIG{TERM} = sub { $got_signal = 'TERM' };
    $SIG{INT}  = sub { $got_signal = 'INT' };

    # Open output file
    open(my $out_fh, '>', $self->{+OUTPUT_FILE})
        or croak "Could not open output file '$self->{+OUTPUT_FILE}': $!";
    $out_fh->autoflush(1);

    # Instantiate parser
    my $parser = $self->{+PARSER};
    $parser = $parser->new() unless ref $parser;

    # Main collection loop
    my $child_exited = 0;
    my $child_exit   = undef;
    my $stdout_eof   = defined($out_r) ? 0 : 1;
    my $stderr_eof   = defined($err_r) ? 0 : 1;

    # Merged if same handle object or err not provided
    $stderr_eof = 1 if defined($out_r) && defined($err_r) && "$out_r" eq "$err_r";

    my $draining = 0;    # Set when we got a signal/parent-gone and are finishing up

    while (1) {
        unless (eval {
            # Check for signal - kill child but keep draining handles
            if ($got_signal && !$draining) {
                $self->_kill_child($child_pid) if $child_pid;
                $draining     = 1;
                $child_exited = 1;
            }

            # Check parent pids
            if (!$draining && $self->{+PARENT_PIDS} && @{$self->{+PARENT_PIDS}}) {
                my $parent_gone = 0;
                for my $ppid (@{$self->{+PARENT_PIDS}}) {
                    unless (_pid_is_running($ppid)) {
                        $parent_gone = 1;
                        last;
                    }
                }
                if ($parent_gone) {
                    $self->_kill_child($child_pid) if $child_pid;
                    $draining     = 1;
                    $child_exited = 1;
                }
            }

            # Read stdout
            unless ($stdout_eof) {
                my @lines = _read_handle($out_r);
                for my $line (@lines) {
                    if (!defined $line) {
                        $stdout_eof = 1;
                        last;
                    }
                    my $event = $parser->parse_io(stream => 'stdout', line => $line, stamp => time);
                    $self->_write_event($out_fh, $event) if $event;
                }
            }

            # Read stderr
            unless ($stderr_eof) {
                my @lines = _read_handle($err_r);
                for my $line (@lines) {
                    if (!defined $line) {
                        $stderr_eof = 1;
                        last;
                    }
                    my $event = $parser->parse_io(stream => 'stderr', line => $line, stamp => time);
                    $self->_write_event($out_fh, $event) if $event;
                }
            }

            # Check if child has exited (only if we started it via waitpid)
            if ($child_pid && $started_child && !$child_exited) {
                my $rv = waitpid($child_pid, WNOHANG);
                if ($rv == $child_pid) {
                    $child_exited = 1;
                    $child_exit   = $?;
                }
            }

            # When we have IPC and can check for an exit and exit code, this
            # is where we will do that check for externally-managed processes
            # (pid provided but not started by us).

            1;
        })
        {
            # Save $@ before the inner eval clobbers it
            my $err = $@;

            # Write the exception as an event to the log
            eval {
                my $err_event = Test2::Harness2::Event->new(
                    event_id   => gen_uuid(),
                    stamp      => time,
                    facet_data => {
                        errors => [{
                            tag     => 'COLLECTOR',
                            details => "Collector exception: $err",
                            fail    => 1,
                        }],
                    },
                );
                $self->_write_event($out_fh, $err_event);
                1;
            } or warn "Failed to write error event: $@";

            # Terminate the child and bail out of the loop
            $self->_kill_child($child_pid) if $child_pid && $started_child;
            last;
        }

        # Check if we're done
        if ($stdout_eof && $stderr_eof) {
            # Drain any remaining child exit if we started it
            if ($child_pid && $started_child && !$child_exited) {
                my $rv = waitpid($child_pid, 0);
                $child_exit   = $? if $rv == $child_pid;
                $child_exited = 1;
            }
            last;
        }
    }

    # Write exit event if we have an exit code
    if (defined $child_exit) {
        my $exit_event = Test2::Harness2::Event->new(
            event_id   => gen_uuid(),
            stamp      => time,
            facet_data => {
                harness_process_exit => parse_exit($child_exit),
            },
        );
        $self->_write_event($out_fh, $exit_event);
    }

    close($out_fh);

    # Restore signal handlers
    $SIG{TERM} = $old_term // 'DEFAULT';
    $SIG{INT}  = $old_int  // 'DEFAULT';

    return 1;
}

sub _set_procname {
    my $self = shift;
    my ($child_pid) = @_;

    my @parts = ('Collector');

    push @parts, $child_pid if $child_pid;

    if ($self->{+LAUNCH}) {
        my $cmd = ref($self->{+LAUNCH}) ? join(' ', @{$self->{+LAUNCH}}) : $self->{+LAUNCH};
        push @parts, $cmd;
    }
    elsif (defined $self->{+OUT_FH} || defined $self->{+ERR_FH}) {
        # Try to show file info
        my @files;
        if (!ref($self->{+OUT_FH}) && defined $self->{+OUT_FH}) {
            push @files, "out=$self->{+OUT_FH}";
        }
        if (!ref($self->{+ERR_FH}) && defined $self->{+ERR_FH}) {
            push @files, "err=$self->{+ERR_FH}";
        }
        push @parts, @files if @files;

        push @parts, $self->{+OUTPUT_FILE} unless @files;
    }
    else {
        push @parts, $self->{+OUTPUT_FILE};
    }

    $0 = join(' - ', @parts);
}

sub _launch_child {
    my $self = shift;

    my $cmd = $self->{+LAUNCH};
    my $env = $self->{+ENV_VARS};

    my ($out_r, $out_w) = Atomic::Pipe->pair(mixed_data_mode => 1);
    my ($err_r, $err_w) = Atomic::Pipe->pair(mixed_data_mode => 1);

    # Save copies of the original STDOUT/STDERR before redirecting
    open(my $orig_stdout, '>&', \*STDOUT) or croak "Could not clone STDOUT: $!";
    open(my $orig_stderr, '>&', \*STDERR) or croak "Could not clone STDERR: $!";

    my $pid;

    if (IS_WIN32) {
        # On Windows there is no fork.  Redirect STDOUT/STDERR to the pipe
        # write ends, spawn via system(1, @cmd) (P_NOWAIT) which returns
        # the child PID immediately, then restore handles.
        _swap_io(\*STDOUT, $out_w->wh);
        _swap_io(\*STDERR, $err_w->wh);
        STDOUT->autoflush(1);
        STDERR->autoflush(1);

        my $ok;
        {
            local @ENV{keys %$env} = values %$env;
            $ok = eval { $pid = system 1, @$cmd; 1 };
        }
        my $err = $@;

        # Restore STDOUT/STDERR immediately after spawn
        open(STDOUT, '>&', $orig_stdout) or croak "Could not restore STDOUT: $!";
        open(STDERR, '>&', $orig_stderr) or croak "Could not restore STDERR: $!";

        if (!$ok || !$pid || $pid < 0) {
            croak "Failed to spawn '@$cmd': " . ($err || $!);
        }
    }
    else {
        # Unix: fork, redirect in the child, exec.
        $pid = fork() // die "Failed to fork child process: $!";

        if (!$pid) {
            # Child process
            $out_r->close();
            $err_r->close();

            _swap_io(\*STDOUT, $out_w->wh);
            _swap_io(\*STDERR, $err_w->wh);
            STDOUT->autoflush(1);
            STDERR->autoflush(1);

            close($orig_stdout);
            close($orig_stderr);

            local @ENV{keys %$env} = values %$env;
            exec(@$cmd) or croak "Failed to exec '@$cmd': $!";
        }

        # Parent continues below
    }

    # Parent (both platforms) - close write ends so reads get EOF
    $out_w->close();
    $err_w->close();

    # Restore original stdout/stderr (no-op path on win32, already restored)
    unless (IS_WIN32) {
        open(STDOUT, '>&', $orig_stdout) or croak "Could not restore STDOUT: $!";
        open(STDERR, '>&', $orig_stderr) or croak "Could not restore STDERR: $!";
    }

    close($orig_stdout);
    close($orig_stderr);

    return ($pid, $out_r, $err_r);
}

sub _swap_io {
    my ($fh, $to) = @_;

    my $orig_fd = fileno($fh);
    croak "Could not get fd for handle" unless defined $orig_fd;

    open($fh, '>&', $to) or croak "Could not redirect fd $orig_fd: $!";

    croak "Handle does not have the expected fd (got " . fileno($fh) . ", wanted $orig_fd)" if fileno($fh) != $orig_fd;
}

sub _wrap_handle {
    my $self = shift;
    my ($handle) = @_;

    # Already an Atomic::Pipe object
    return $handle if blessed($handle) && $handle->isa('Atomic::Pipe');

    # Pipe or fifo filehandle -- wrap in Atomic::Pipe with mixed_data_mode
    if (-p $handle) {
        my $ap = Atomic::Pipe->from_fh('<&', $handle);
        $ap->set_mixed_data_mode();
        return $ap;
    }

    # Regular file handle -- use plain line-reader shim, no Atomic::Pipe.
    return Test2::Harness2::Collector::_FileLineReader->new($handle);
}

sub _read_handle {
    my ($handle) = @_;

    # Atomic::Pipe handles
    if (blessed($handle) && $handle->isa('Atomic::Pipe')) {
        my @lines;

        while (1) {
            my ($type, $data) = $handle->get_line_burst_or_data();
            last unless defined $type;
            push @lines, $data;
        }

        push @lines, undef if $handle->eof();

        return @lines;
    }

    # _FileLineReader shim
    return $handle->read_lines();
}

sub _write_event {
    my $self = shift;
    my ($fh, $event) = @_;

    return unless $event;

    my $json = $event->as_json();
    print $fh $json, "\n";
}

sub _kill_child {
    my $self = shift;
    my ($pid) = @_;

    return unless $pid;
    return unless _pid_is_running($pid);

    if (IS_WIN32) {
        # Windows has no SIGTERM.  kill(9, $pid) terminates the process.
        kill(9, $pid);
        my $rv = waitpid($pid, 0);
        return $?;
    }

    # Unix: try TERM first, escalate to KILL after timeout
    kill('TERM', $pid);

    my $timeout = $self->{+KILL_TIMEOUT};
    my $start   = time;

    while (time - $start < $timeout) {
        my $rv = waitpid($pid, WNOHANG);
        return $? if $rv == $pid;
        sleep(0.1);
    }

    # Force kill
    kill('KILL', $pid);
    my $rv = waitpid($pid, 0);
    return $?;
}

sub _pid_is_running {
    my ($pid) = @_;

    return 0 unless $pid;

    local $!;

    # kill(0, $pid) works on both Unix and Windows to check if a process
    # is running and we have permission to signal it.
    return 1 if kill(0, $pid);

    # On Unix, ESRCH means no such process.  On Windows $! is set to a
    # platform-specific value, but kill(0) returning false is sufficient.
    if (!IS_WIN32) {
        require POSIX;
        return 0 if $! == POSIX::ESRCH();

        # Some other error (e.g. EPERM) - process exists but not ours
        return -1;
    }

    return 0;
}

sub interpose {
    my ($class, %params) = @_;

    croak "interpose() is a class method"           if ref $class;
    croak "interpose() is not supported on Windows" if IS_WIN32;
    croak "'output_file' is a required parameter" unless defined $params{output_file};

    my ($out_r, $out_w) = Atomic::Pipe->pair(mixed_data_mode => 1);
    my ($err_r, $err_w) = Atomic::Pipe->pair(mixed_data_mode => 1);

    open(my $orig_stdout, '>&', \*STDOUT) or croak "Could not clone STDOUT: $!";
    open(my $orig_stderr, '>&', \*STDERR) or croak "Could not clone STDERR: $!";

    my $pid = fork() // die "Failed to fork for interpose: $!";

    $params{out_r}       = $out_r;
    $params{out_w}       = $out_w;
    $params{err_r}       = $err_r;
    $params{err_w}       = $err_w;
    $params{orig_stdout} = $orig_stdout;
    $params{orig_stderr} = $orig_stderr;

    # Child resumes caller's execution path
    return $class->_interpose_child(\%params) unless $pid;

    # Parent becomes the collector and exits when done -- does not return
    $params{pid} = $pid;
    $class->_interpose_parent(\%params);
}

sub _interpose_parent {
    my ($class, $params) = @_;

    my $out_w       = delete $params->{out_w};
    my $err_w       = delete $params->{err_w};
    my $orig_stdout = delete $params->{orig_stdout};
    my $orig_stderr = delete $params->{orig_stderr};

    $out_w->close();
    $err_w->close();

    # Restore original stdout/stderr so the collector can still print
    # warnings/diagnostics to the real terminal.
    open(STDOUT, '>&', $orig_stdout) or croak "Could not restore STDOUT: $!";
    open(STDERR, '>&', $orig_stderr) or croak "Could not restore STDERR: $!";
    close($orig_stdout);
    close($orig_stderr);

    # Remap internal keys to spec names that init() expects
    $params->{stdout}        = delete $params->{out_r};
    $params->{stderr}        = delete $params->{err_r};
    $params->{_OWNS_CHILD()} = 1;

    my $self = $class->new(%$params);

    unless (eval { $self->_run_collector(); 1 }) {
        warn "Collector (interpose) died: $@";
        exit(1);
    }

    exit(0);
}

sub _interpose_child {
    my ($class, $params) = @_;

    $params->{out_r}->close();
    $params->{err_r}->close();

    _swap_io(\*STDOUT, $params->{out_w}->wh);
    _swap_io(\*STDERR, $params->{err_w}->wh);
    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    close($params->{orig_stdout});
    close($params->{orig_stderr});
}

sub wait {
    my $self = shift;

    # On Windows the collector ran inline, nothing to wait for
    my $cpid = $self->{+COLLECTOR_PID} or return;

    my $rv   = waitpid($cpid, 0);
    my $exit = $?;

    $self->{+EXIT_CODE} = $exit;

    return $exit;
}

1;

# Thin shim so that regular file handles can be read with the same interface
# as Atomic::Pipe handles in the main collection loop.
package Test2::Harness2::Collector::_FileLineReader;

sub new {
    my ($class, $fh) = @_;
    return bless {fh => $fh, eof => 0}, $class;
}

sub read_lines {
    my $self = shift;
    my $fh   = $self->{fh};

    return () if $self->{eof};

    my @lines;
    while (defined(my $line = <$fh>)) {
        chomp $line;
        push @lines, $line;
    }

    # If readline returned undef we hit EOF
    if (eof($fh)) {
        $self->{eof} = 1;
        push @lines, undef;
    }

    return @lines;
}

1;
