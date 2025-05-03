package Test2::Harness::Collector;
use strict;
use warnings;

use IO::Select;
use File::Spec;
use Atomic::Pipe;

use Carp qw/croak/;
use POSIX ":sys_wait_h";
use File::Temp qw/tempfile/;
use File::Path qw/remove_tree/;
use Time::HiRes qw/time sleep/;

use Test2::Harness::Collector::Auditor::Job;
use Test2::Harness::Collector::IOParser::Stream;

use Test2::Harness::Util qw/mod2file parse_exit open_file chmod_tmp/;
use Test2::Harness::Util::JSON qw/decode_json encode_json decode_json_file/;
use Test2::Harness::IPC::Util qw/pid_is_running swap_io start_process ipc_connect ipc_loop inflate set_procname/;

BEGIN {
    if (eval { require Linux::Inotify2; 1 }) {
        *USE_INOTIFY = sub() { 1 };
    }
    else {
        *USE_INOTIFY = sub() { 0 };
    }
}

our $VERSION = '2.000005';

use Test2::Harness::Util::HashBase qw{
    merge_outputs

    <encoding
    <handles
    <peeks

    <end_callback

    <step
    <parser
    <auditor
    <output
    <output_cb

    root_pid

    <run
    <job
    <test_settings
    <command

    <workdir

    <start_times

    <run_id
    <job_id
    <job_try
    <skip

    +clean
    +buffer

    <tempdir

    <interactive
    <always_flush
};

sub init {
    my $self = shift;

    croak "'parser' is a required attribute"
        unless $self->{+PARSER};

    croak "'output' is a required attribute"
        unless $self->{+OUTPUT};

    my $ref = ref($self->{+OUTPUT});

    if ($ref eq 'CODE') {
        $self->{+OUTPUT_CB} = $self->{+OUTPUT};
    }
    elsif ($ref eq 'GLOB') {
        my $fh = $self->{+OUTPUT};
        $self->{+OUTPUT_CB} = sub { print $fh encode_json($_) . "\n" for @_ };
    }
    elsif ($self->{+OUTPUT}->isa('Atomic::Pipe')) {
        my $wp = $self->{+OUTPUT};
        $self->{+OUTPUT_CB} = sub { $wp->write_message(encode_json($_)) for @_ };
    }
    else {
        croak "Unknown output type: $self->{+OUTPUT} ($ref)";
    }

    $self->{+START_TIMES} //= [times()];

    $self->{+RUN_ID}        //= 0;
    $self->{+JOB_ID}        //= 0;
    $self->{+JOB_TRY}       //= 0;
    $self->{+MERGE_OUTPUTS} //= 0;

    my ($out_r, $out_w) = Atomic::Pipe->pair(mixed_data_mode => 1);
    my ($err_r, $err_w) = $self->{+MERGE_OUTPUTS} ? ($out_r, $out_w) : Atomic::Pipe->pair(mixed_data_mode => 1);

    $self->{+HANDLES} = {
        out_r => $out_r,
        out_w => $out_w,
        err_r => $err_r,
        err_w => $err_w,
    };
}

my $warned = 0;
sub collect {
    my $class = shift;
    my %params;

    if (@_ == 1) {
        my ($in) = @_;
        if ($in =~ m/\.json$/ || -f $in) {
            %params = %{decode_json_file($in, unlink => 1)};
        }
        else {
            %params = %{decode_json($in)};
        }
    }
    else {
        %params = @_;
    }

    die "No root pid" unless $params{root_pid};
    $class->setsid if $params{setsid};

    my ($self, $cb, $cleanup, @ipc);
    if ($params{job}) {
        ($self, $cb, $cleanup, @ipc) = $class->collect_job(%params);
    }
    elsif ($params{command}) {
        ($self, $cb, @ipc) = $class->collect_command(%params);
    }
    else {
        die "Was not given either a 'job' or 'command' to collect";
    }

    $self->{+SKIP} = $params{skip} if $params{skip};

    open(my $stderr, '>&', \*STDERR) or die "Could not clone STDERR";
    local $SIG{__WARN__} = sub { print $stderr @_ };

    my $start_pid = $$;
    my $exit;
    my $ok = eval { $exit = $self->launch_and_process($cb); 1 } // 0;
    my $err = $@;

    if ($cleanup && $start_pid == $$) {
        eval { $cleanup->(); 1 } or warn $@;
    }

    if (!$ok) {
        eval { $self->_die($err, no_exit => 1) };
        eval { print $stderr $err };
        eval { print STDERR "Test2 Harness Collector Error: $err" };
        exit(255);
    }

    return 0 unless $params{forward_exit};

    if ($exit->{sig}) {
        delete $SIG{$_} for grep { $SIG{$_} } keys %SIG;
        kill($exit->{sig}, $$);
        sleep 1;
        exit(255); # In case signal cannot be forwarded
    }

    exit($exit->{err} // 0);
}

sub setsid {
    POSIX::setsid() or die "Could not setsid: $!";
    my $pid = fork // die "Could not fork: $!";
    exit(0) if $pid;
}

sub collect_command {
    my $class = shift;
    my %params = @_;

    my $root_pid = $params{root_pid} or die "No root pid";
    my $io_pipes = $params{io_pipes} or die "IO pipes are required";

    my ($stdout, $stderr);
    $stdout = Atomic::Pipe->from_fh('>&=', \*STDOUT);
    $stdout->set_mixed_data_mode();

    if ($io_pipes > 1) {
        $stderr = Atomic::Pipe->from_fh('>&=', \*STDERR);
        $stderr->set_mixed_data_mode();
    }

    my $handler = sub {
        for my $e (@_) {
            $stdout->write_message(encode_json($e));
            next unless $stderr;
            my $event_id = $e->{event_id} or next;
            $stderr->write_message(qq/{"event_id":"$event_id"}/);
        }
    };

    my $parser = Test2::Harness::Collector::IOParser->new(
        job_id  => 0,
        job_try => 0,
        run_id  => 0,
        type    => $params{type} // 'unknown',
        name    => $params{name} // 'unknown',
        tag     => $params{tag}  // $params{name} // $params{type} // 'unknown',
    );

    return $class->new(
        parser   => $parser,
        job_id   => 0,
        job_try  => 0,
        run_id   => 0,
        root_pid => $root_pid,
        output   => $handler,
        command  => $params{command},
        always_flush => 1,
    );
}

sub collect_job {
    my $class = shift;
    my %params = @_;

    my $root_pid = $params{root_pid} or die "No root pid";

    my $ts  = inflate($params{test_settings}, 'Test2::Harness::TestSettings') or die "No test_settings provided";
    my $run = inflate($params{run},           'Test2::Harness::Run')          or die "No run provided";
    my $job = inflate($params{job},           'Test2::Harness::Run::Job')     or die "No job provided";

    die "No workdir provided" unless $params{workdir};
    my $tempdir = File::Temp::tempdir(DIR => $params{workdir}, TEMPLATE => "XXXXXX");
    $params{tempdir} = $tempdir;
    chmod_tmp($tempdir);

    my ($inst_ipc, $inst_con) = ipc_connect($run->instance_ipc);
    my ($agg_ipc,  $agg_con)  = ipc_connect($run->aggregator_ipc);
    my $agg_use_io            = $run->aggregator_use_io;

    my $inst_handler = sub {
        my ($e) = @_;

        my $fd = $e->{facet_data};

        my ($halt, $result);
        $halt = $fd->{control}->{details} || 'halt' if $fd->{control} && $fd->{control}->{halt};

        if (my $end = $fd->{harness_job_end}) {
            $result = {
                fail => $end->{fail},
                retry => $end->{retry},
            };
        }

        return unless $halt || $result;

        $inst_con->send_and_get(
            job_update => {
                run_id => $run->run_id,
                job_id => $job->job_id,
                result => $result,
                halt   => $halt,
            },
        );
    };

    my $child_pid;
    my $handler;
    if ($agg_con) {
        $handler = sub {
            for my $e (@_) {
                unless (eval { $agg_con->send_message({event => $e}); 1 }) {
                    my $err = $@;
                    die $err unless $err =~ m/Disconnected pipe/;

                    kill('TERM', $child_pid) if $child_pid;
                    exit(255);
                }

                $inst_handler->($e) if $inst_con;
            }
        };
    }
    elsif ($agg_use_io && $run->send_event_cb) {
        my $send_event = $run->send_event_cb;
        $handler = sub {
            for my $e (@_) {
                $send_event->($e);
                $inst_handler->($e) if $inst_con;
            }
        };
    }
    else {
        $handler = sub {
            for my $e (@_) {
                print STDOUT encode_json($e), "\n";
                $inst_handler->($e) if $inst_con;
            }
        };
    }

    if ($job->test_file->check_feature('collector_echo')) {
        my $tmpdir = $params{tempdir};
        my $file   = File::Spec->catfile($tmpdir, 'COLLECTOR-ECHO');
        $ENV{TEST2_HARNESS_COLLECTOR_ECHO_FILE} = $file;

        open(my $fh, '>', $file) or die "Could not open file $file: $!";

        my $old_handler = $handler;
        $handler = sub {
            print $fh encode_json($_), "\n" for @_;
            $fh->flush();
            $old_handler->(@_);
        };
    }

    my %create_params = (
        run_id  => $run->run_id,
        job_id  => $job->job_id,
        job_try => $job->try,
        file    => $job->test_file->file,
        name    => $job->test_file->relative,
    );

    my $auditor = Test2::Harness::Collector::Auditor::Job->new(%create_params);
    my $parser  = Test2::Harness::Collector::IOParser::Stream->new(%create_params, type => 'test');

    my $self = $class->new(
        %create_params,
        %params,
        parser   => $parser,
        auditor  => $auditor,
        output   => $handler,
        root_pid => $root_pid,
    );

    return (
        $self,
        sub {
            my $pid = shift;

            $child_pid = $pid;

            $inst_con->send_and_get(
                job_update => {
                    run_id => $run->run_id,
                    job_id => $job->job_id,
                    pid    => $pid,
                },
            );
        },
        sub {
            remove_tree($tempdir, {safe => 1, keep_root => 0}) if -d $tempdir;
        },
        $inst_ipc => $inst_con,
        $agg_ipc =>  $agg_con,
    );
}

sub event_timeout     { my $ts = shift->test_settings or return; $ts->event_timeout }
sub post_exit_timeout { my $ts = shift->test_settings or return; $ts->post_exit_timeout }

sub launch_command {
    my $self = shift;

    return ([$^X, '-e', "print \"1..0 # SKIP $self->{+SKIP}\\n\""])
        if $self->{+SKIP};

    if(my $job = $self->{+JOB}) {
        my $run = $self->{+RUN};
        my $ts  = $self->{+TEST_SETTINGS};

        my ($cmd, $env) = $job->launch_command($run, $ts);

        my $cb;
        my $dir = $ts->ch_dir;
        if($dir || $env) {
            $cb = sub {
                chdir($dir) if $dir;
                $ENV{$_} = $env->{$_} for keys %{$env //= {}};
            };
        }

        return ($cmd, $cb);
    }

    return ($self->{+COMMAND}) if $self->{+COMMAND};

    die "No command!";
}

sub launch_and_process {
    my $self = shift;
    my ($parent_cb) = @_;

    my ($cmd, $cb) = $self->launch_command;
    my $pid = start_process($cmd, sub { $self->setup_child(); $cb->() if $cb });

    set_procname(set => ['collector', $pid]);

    $parent_cb->($pid) if $parent_cb;
    return $self->process($pid);
}

sub _pre_event {
    my $self = shift;
    my (%data) = @_;

    my $peek = $data{peek};
    my $canon = !$peek || $peek eq 'peek_end';

    my @events = $self->{+PARSER}->parse_io(\%data);

    if ($canon) {
        @events = $self->{+AUDITOR}->audit(@events) if $self->{+AUDITOR};
        $self->{+OUTPUT_CB}->(@events);
    }
    else {
        for my $event (@events) {
            my $fd = $event->{facet_data};

            # Only info (stderr/stdout) should be peeked.
            next unless $fd->{info} && @{$fd->{info}};
            $event->{facet_data}->{harness}->{peek} = 1;

            my %keep = (harness => 1, info => 1, trace => 1, hubs => 1, from_tap => 1);
            delete $fd->{$_} for grep { !$keep{$_} } keys %$fd;
            $self->{+OUTPUT_CB}->($event);
        }
    }

    return;
}

sub _die {
    my $self = shift;
    my ($msg, %params) = @_;

    my @caller = caller();
    $msg .= " at $caller[1] line $caller[2].\n" unless $msg =~ m/\n$/;

    my $stamp = time;
    $self->_pre_event(
        %{$params{event_data} // {}},
        stream => 'process',
        stamp  => $stamp,
        event  => {
            facet_data => {
                %{$params{facets} // {}},
                errors => [{tag => 'ERROR', details => $msg, fail => 1}],
                trace  => {frame => \@caller, stamp => $stamp},
            },
        },
    );

    exit(255) unless $params{no_exit};
}

sub _warn {
    my $self = shift;
    my ($msg, %params) = @_;

    my @caller = caller();
    $msg .= " at $caller[1] line $caller[2].\n" unless $msg =~ m/\n$/;

    my $stamp = time;
    $self->_pre_event(
        %{$params{event_data} // {}},
        stream => 'process',
        stamp  => $stamp,
        event  => {
            facet_data => {
                %{$params{facets} // {}},
                info  => [{tag => 'WARNING', details => $msg, debug => 1}],
                trace => {frame => \@caller, stamp => $stamp}
            },
        },
    );
}

sub setup_child {
    my $self = shift;

    $self->setup_child_env_vars();
    $self->setup_child_output();
    $self->setup_child_input();
}

sub setup_child_output {
    my $self = shift;

    my $handles = $self->handles;

    swap_io(\*STDOUT, $handles->{out_w}->wh, sub { $self->_die(@_) });
    swap_io(\*STDERR, $handles->{err_w}->wh, sub { $self->_die(@_) });

    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    select STDOUT;

    $ENV{T2_HARNESS_PIPE_COUNT} = $self->{+MERGE_OUTPUTS} ? 1 : 2;
    require Test2::Harness::Collector::Child;
    {
        no warnings 'once';
        $Test2::Harness::Collector::Child::STDOUT_APIPE = $handles->{out_w};
        $Test2::Harness::Collector::Child::STDERR_APIPE = $handles->{err_w} if $self->{+MERGE_OUTPUTS};
    }

    return;
}

sub setup_child_input {
    my $self = shift;

    my $run = $self->{+RUN};
    if ($run && $run->interactive) {
        my $pid = $run->interactive_pid;

        close(STDIN);
        open(STDIN, "<", "/proc/$pid/fd/0") or die "Could not connect to STDIN from pid $pid: $!";
        return;
    }

    my $ts = $self->{+TEST_SETTINGS} or return;

    if (my $in_file = $ts->input_file) {
        my $in_fh = open_file($in_file, '<');
        swap_io(\*STDIN, $in_fh, sub { $self->_die(@_) });
    }
    else {
        my $input = $ts->input // "";
        my ($fh, $file) = tempfile("input-$$-XXXX", TMPDIR => 1, UNLINK => 1);
        print $fh $input;
        close($fh);
        open($fh, '<', $file) or die "Could not open '$file' for reading: $!";
        swap_io(\*STDIN, $fh, sub { $self->_die(@_) });
    }

    return;
}

sub setup_child_env_vars {
    my $self = shift;

    my $ts = $self->{+TEST_SETTINGS} or return;

    delete $ENV{T2_HARNESS_PIPE_COUNT};

    $ENV{TEMPDIR}  = $self->tempdir;
    $ENV{TEMP_DIR} = $self->tempdir;
    $ENV{TMPDIR}   = $self->tempdir;
    $ENV{TMP_DIR}  = $self->tempdir;

    $ENV{T2_TRACE_STAMPS} = 1;

    $ENV{HARNESS_ACTIVE}       = 1;
    $ENV{TEST2_HARNESS_ACTIVE} = $VERSION;
    $ENV{T2_HARNESS_RUN_ID}    = $self->run_id;

    if (my $job = $self->{+JOB}) {
        $ENV{T2_HARNESS_JOB_ID}     = $job->job_id;
        $ENV{T2_HARNESS_JOB_IS_TRY} = @{$job->results // []};
        $ENV{T2_HARNESS_JOB_FILE}   = $job->test_file->file;
    }

    my $env = $ts->env_vars;
    {
        no warnings 'uninitialized';
        $ENV{$_} = $env->{$_} for keys %$env;
    }

    return;
}

sub close_parent_handles {
    my $self = shift;

    my $handles = $self->handles;

    delete($handles->{out_r})->close();
    delete($handles->{err_r})->close();

    1;
}

sub process {
    my $self = shift;
    my ($child_pid) = @_;

    delete($self->handles->{out_w})->close();
    delete($self->handles->{err_w})->close();

    if (my $job = $self->{+JOB}) {
        my $file   = $job->test_file;
        my $job_id = $job->job_id;

        my $stamp = time;
        $self->_pre_event(
            stream => 'process',
            stamp  => $stamp,
            event  => {
                facet_data => {
                    trace => {frame => [__PACKAGE__, __FILE__, __LINE__], stamp => $stamp},

                    harness_job => {
                        %{$job->process_info},

                        test_file     => $file->process_info,
                        test_settings => $self->{+TEST_SETTINGS},

                        # For compatibility
                        file   => $file->relative,
                        job_id => $job_id,
                    },

                    harness_job_launch => {
                        job_id => $job_id,
                        stamp  => $stamp,
                        retry  => $job->try,
                        pid    => $child_pid,
                    },

                    harness_job_start => {
                        file     => $file->file,
                        abs_file => $file->file,
                        rel_file => $file->relative,

                        stamp   => $stamp,
                        job_id  => $job_id,
                        details => "Launched " . $file->relative . " as job $job_id.",
                    },
                },
            },
        );
    }

    my $exit;
    my $ok = eval { $exit = $self->_process($child_pid); 1 };
    my $err = $@;

    if ($self->end_callback) {
        my $ok2 = eval { $self->end_callback->($self); 1};
        $err = $ok ? $@ : "$err\n$@";
        $ok &&= $ok2;
    }

    die $err unless $ok;

    return $exit;
}

sub _add_item {
    my $self = shift;
    my ($stream, $val, $peek) = @_;

    if(ref($val) && $val->{facet_data}->{control}->{encoding}) {
        require Encode;
        $self->{+ENCODING} = $val->{facet_data}->{control}->{encoding};
    }

    my $buffer = $self->{+BUFFER} //= {};
    my $seen   = $buffer->{seen}  //= {};

    push @{$buffer->{$stream}} => [time, $val, $peek];

    $self->_flush() unless keys(%$seen);

    return unless ref($val);

    my $event_id = $val->{event_id} or die "Event has no ID!";

    my $count = ++($seen->{$event_id});
    return unless $count >= ($self->{+MERGE_OUTPUTS} ? 1 : 2);

    $self->_flush(to => $event_id);
}

sub _flush {
    my $self = shift;
    my %params = @_;

    my $to = $params{to};
    my $age = $params{age};

    my $buffer = $self->{+BUFFER} //= {};
    my $seen   = $buffer->{seen}  //= {};

    for my $stream (qw/stderr stdout/) {
        while (1) {
            my $set = shift(@{$buffer->{$stream}}) or last;
            my ($stamp, $val, $peek) = @$set;

            if ($age && (time - $stamp) < $age) {
                unshift @{$buffer->{$stream}} => $set;
                last;
            }

            if (ref($val)) {
                # Send the event, unless it came via STDERR in which case it should only be a hashref with an event_id
                $self->_pre_event(stream => $stream, data => $val, stamp => $stamp)
                    unless $stream eq 'stderr';

                last if $to && $val->{event_id} eq $to;
            }
            else {
                $self->_pre_event(stream => $stream, line => $val, stamp => $stamp, peek => $peek);
            }
        }
    }
}

sub _process {
    my $self = shift;
    my ($pid) = @_;

    # Some initial signal handlers to make sure the child is killed if we die.
    my $sig_stamp;
    for my $sigtype (qw/INT TERM/) {
        my $sig = $sigtype;
        $SIG{$sig} = sub {
            $sig_stamp //= time;
            $self->_warn("$$: Got SIG${sig}, forwarding to child process $pid.\n");
            kill($sigtype, $pid);

            if (time - $sig_stamp > 5) {
                $SIG{$sig} = 'DEFAULT';
                kill($sig, $$);
            }
        };
    }

    local $SIG{PIPE} = 'IGNORE';
    $self->{+BUFFER} = {seen => {}, stderr => [], stdout => []};

    my $stdout = $self->handles->{out_r};
    my $stderr = $self->handles->{err_r};

    my $last_event = time;

    my ($exited, $exit);
    my $reap = sub {
        my ($flags) = @_;

        return -1 if $exited;
        return -1 if defined $exit;

        local ($!, $?);

        my $check = waitpid($pid, $flags);
        my $code = $?;

        return -1 if $check < 0;
        return 0 if $check == 0 && $flags == WNOHANG;

        die("waitpid returned $check, expected $pid") if $check != $pid;

        $exit = $code;
        $exited = time;
        $last_event = $exited;

        return 1;
    };

    my $auditor = $self->{+AUDITOR};
    my $ev_timeout = $self->event_timeout;
    my $pe_timeout = $self->post_exit_timeout;

    my $handles = [];
    my $broken = {};
    push @$handles => [$stdout->rh, sub { $last_event = time; $self->handle_event(stdout => $stdout, $broken) }, eof => sub { $broken->{$stdout} || $stdout->eof }, name => 'stdout'];
    push @$handles => [$stderr->rh, sub { $last_event = time; $self->handle_event(stderr => $stderr, $broken) }, eof => sub { $broken->{$stderr} || $stderr->eof }, name => 'stderr']
        unless $self->{+MERGE_OUTPUTS};

    my %timeout_warns;

    ipc_loop(
        handles   => $handles,
        sigchild  => sub { $reap->(0) },
        wait_time => sub { $sig_stamp ? 0 : 0.2 },
        signals   => sub { $sig_stamp //= time; kill($_[0], $pid) },

        iteration_start => sub {
            $self->{+STEP}->() if $self->{+STEP};
            $self->peek_event($pid, stderr => $stderr, $broken);
            $self->peek_event($pid, stdout => $stdout, $broken);
            $self->_flush(age => 0.5);
        },

        iteration_end => sub {
            my $out = 0;
            if ($self->{+INTERACTIVE} || $self->{+ALWAYS_FLUSH}) {
                $self->_flush();
            }
            else {
                # Anything that has been sitting in the buffer for more than half a second should probably get rendered
                $self->_flush(age => 0.5);
            }
            $out++ if $reap->(WNOHANG) > 0;
            return $out;
        },

        end_check => sub {
            my %params = @_;
            return 1 if $sig_stamp;

            # Wait for all output
            return 0 if $params{did_work};

            if ($self->{+ROOT_PID} && !pid_is_running($self->{+ROOT_PID})) {
                $self->_warn("Yath exited, killing process.");
                kill('TERM', $pid);
                return 1;
            }

            if (defined $exited) {
                for my $h (@$handles) {
                    my ($x, $y, %params) = @$h;

                    my $timeout;
                    if (my $delta = int(time - $last_event)) {
                        $timeout = 1 if $delta > 10;

                        unless ($timeout) {
                            if ($timeout_warns{main}) {
                                my $countdown = int(10 - $delta);
                                unless ($timeout_warns{$countdown}) {
                                    warn "  $countdown...\n";
                                    $timeout_warns{$countdown} = 1;
                                }
                            }
                            else {
                                warn "Testing looks complete, but a filehandle is still open (Did a plugin or renderer fork without an exec?), will timeout in 10 seconds...\n";
                                $timeout_warns{main} = 1;
                            }
                        }
                    }

                    return 0 unless $params{eof}->() || $timeout;
                }

                return 1 if !$auditor;
                return 1 if $auditor->has_plan;
                return 1 if $exit;                # If the exit value is not true we do not wait for post-exit timeout
                return 1 unless $pe_timeout;

                my $delta = int(time - $last_event);
                if ($delta > $pe_timeout) {

                    $self->_die(
                        "Post-exit timeout after $delta seconds. This means your test exited without a issuing plan, but STDOUT remained open, possibly in a child process. At timestamp '$last_event' the output stopped and the test has since timed out.\n",
                        facets  => {harness => {timeout => {post_exit => $delta}}},
                        no_exit => 1,
                    );

                    return 1;
                }
            }

            if ($ev_timeout) {
                my $delta = int(time - $last_event);

                if ($delta > $ev_timeout) {
                    $self->_die(
                        "Event timeout after $delta seconds. This means your test stopped producing output too long and will be terminated forcefully.\n",
                        facets  => {harness => {timeout => {events => $delta}}},
                        no_exit => 1,
                    );

                    return 1;
                }
            }

            return 0;
        },
    );

    $self->_flush();

    local $SIG{CHLD} = 'IGNORE';
    unless (defined($exit // $exited) || $reap->(WNOHANG)) {
        $self->_die("Sending 'TERM' signal to process...\n", no_exit => 1);
        my $did_kill = kill('TERM', $pid);

        my $start = time;
        while ($did_kill) {
            my $delta = time - $start;
            if ($delta > 10) {
                $self->_die("Sending 'KILL' signal to process...\n", no_exit => 1);
                last unless kill('KILL', $pid);

                $reap->(0);
                $exit   //= 255;
                $exited //= 0;
                last;
            }

            last if $reap->(WNOHANG);

            sleep(0.2);
        }
    }

    my $start_times = $self->{+START_TIMES};
    my $end_times = [times];
    my $times = [];
    while (@$start_times) {
        push @$times => shift(@$end_times) - shift(@$start_times);
    }

    # This can be undef if the test was killed by a signal the interrupts sigchild
    $exit //= 65280; # 255 << 8, the number it would have from an exit(255)

    my $ret = parse_exit($exit);

    $self->_pre_event(
        stream => 'process',
        stamp  => $exited,
        event  => {
            facet_data => {
                trace => {frame => [__PACKAGE__, __FILE__, __LINE__], stamp => $exited},

                harness_job_exit => {
                    job_id => $self->job_id,
                    exit   => $exit,
                    codes  => $ret,
                    stamp  => $exited,
                    retry  => $self->should_retry($exit),
                    times  => $times,
                },
            },
        },
    );

    return $ret;
}

sub peek_event {
    my $self = shift;
    my ($pid, $name, $fh, $broken) = @_;

    my $last_peek = $self->{+PEEKS}->{$name} // ['', 0];

    my ($type, $val) = $self->get_line_burst_or_data($name, $fh, broken => $broken, peek_line => 1);
    return unless $type;

    if ($type eq 'peek') {
        $val = $self->decode_line($val) if $self->{+ENCODING};
        return if $val =~ m/[\n\r]+$/;
        return if $val eq $last_peek->[0];

        my $inotify;
        if (USE_INOTIFY) {
            if (-e "/proc/$pid/fd/0") {
                $inotify = Linux::Inotify2->new();
                $inotify->blocking(0);
                $inotify->watch("/proc/$pid/fd/0", Linux::Inotify2::IN_ACCESS());
            }
        }

        $self->{+PEEKS}->{$name} = [$val, $inotify];
        $self->_add_item($name => $val, 'peek');
        return;
    }

    # If we get an item and it is not a peek we need to handle it.
    $self->_handle_event($name, $type, $val);

    return;
}

sub handle_event {
    my $self = shift;
    my ($name, $fh, $broken) = @_;

    my $out = 0;
    while (1) {
        my ($type, $val) = $self->get_line_burst_or_data($name, $fh, broken => $broken);
        last unless $type;

        $out .= $self->_handle_event($name, $type, $val);
    }

    return $out++;
}

sub get_line_burst_or_data {
    my $self = shift;
    my ($name, $fh, %params) = @_;

    my $broken = $params{broken};

    return if $broken && $broken->{$fh};

    my ($type, $val);
    if (eval { ($type, $val) = $fh->get_line_burst_or_data(%params); 1 }) {
        return ($type, $val);
    }

    my $err = $@ || "An error occured";

    warn $err;
    $broken->{$fh} = $err if $broken;

    return;
}

sub _handle_event {
    my $self = shift;
    my ($name, $type, $val) = @_;

    if ($type eq 'message') {
        my $decoded = decode_json($val);
        $self->_add_item($name => $decoded);
        return 1;
    }

    if ($type eq 'line') {
        $val = $self->decode_line($val) if $self->{+ENCODING};

        my $chomp = chomp($val);

        my $peek = $self->{+PEEKS}->{$name};
        if ($peek) {
            my $ref = delete $self->{+PEEKS}->{$name};
            $peek = 'peek_end';
            $val =~ s/^\Q$ref->[0]\E// if $ref->[1] && $ref->[1]->poll;
        }

        $self->_add_item($name => $val, $peek);
        return 1;
    }

    chomp($val);
    die("Invalid type '$type': $val");
}

sub decode_line {
    my $self = shift;
    my ($val) = @_;

    my $encoding = $self->{+ENCODING} or return $val;

    return Encode::decode($encoding, $val);
}

sub should_retry {
    my $self = shift;
    my ($exit) = @_;
    return 0 unless $exit;

    my $ts = $self->test_settings or return 0;
    return 0 unless $ts->allow_retry;
    return 0 unless $ts->retry;
    return 1 if $self->job_try < $ts->retry;
    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Collector - FIXME

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

