package Test2::Harness::Runner::Preloading::Stage;
use strict;
use warnings;

our $VERSION = '2.000000';

my %ORIG_SIG;
BEGIN { %ORIG_SIG = %SIG }

use goto::file();
use Scope::Guard;

use POSIX qw/:sys_wait_h/;

use Test2::Harness::Util qw/mod2file parse_exit/;
use Test2::Harness::IPC::Util qw/start_process ipc_connect ipc_warn ipc_loop pid_is_running inflate/;
use Test2::Harness::Util::JSON qw/decode_json encode_json/;

use Test2::Harness::Collector::Preloaded;

use Test2::Harness::Util::HashBase qw{
    <test_settings
    <name
    <tree
    <ipc_info
    <preloads
    <retry_delay
    <stage

    <reloader
    <restrict_reload

    <pid <parent <root_pid

    <last_launch
    <last_exit
    <last_exit_code

    <children
    <terminated
};

our ($ERROR, $EXIT, $DO);
sub import {
    my $class = shift;
    my ($do) = @_;

    return unless $do;

    if ($do eq 'start') {
        local ($., $_, $@, $!, $?);
        local $SIG{TERM} = $SIG{TERM};
        local $SIG{INT}  = $SIG{INT};
        local $SIG{CHLD} = $SIG{CHLD};
        local $SIG{HUP}  = $SIG{HUP};

        STDOUT->autoflush(1);
        STDERR->autoflush(1);

        my $ok = eval {
            my ($json) = @ARGV;

            my $self = $class->new(decode_json($json));

            my $got = $self->start();
            $EXIT = $got->{exit} if exists $got->{exit};

            if (my $test = $got->{run_test}) {
                $EXIT = Test2::Harness::Collector::Preloaded->collect(%$test, orig_sig => \%ORIG_SIG, stage => $self, root_pid => $self->{+ROOT_PID});
            }
            elsif (my $spawn = $got->{run_spawn}) {
                $EXIT = Test2::Harness::Collector::Preloaded->spawn(%$spawn, orig_sig => \%ORIG_SIG, stage => $self);
            }

            1;
        };
        $ERROR = $@ unless $ok;
    }
    else {
        $ERROR //= "Invalid action '$do'";
    }
}

sub launch {
    my $class = shift;
    my %params = @_;

    $params{parent} //= $$;

    my $ts = $params{test_settings};
    my $early = $params{preload_early};

    my $pkg = __PACKAGE__;

    my %seen;
    my $pid = start_process([
        $^X,                                                                                      # Call current perl
        (map { ("-I$_") } grep { -d $_ && !$seen{$_}++ } @INC),                                   # Use the dev libs specified
        (map { ("-I$_") } grep { -d $_ && !$seen{$_}++ } @{$ts->includes}),                       # Use the test libs
        (map { my $args = $early->{$_}; "-m$_=" . join(',', @$args) } @{$early->{'@'} // []}),    # Early preloads
        "-m${class}=start",                                                                       # Load Stage
        '-e' => "\$${pkg}\::ERROR ? die \$${pkg}\::ERROR : exit(\$${pkg}\::EXIT // 255)",         # Run it.
        encode_json(\%params),                                                                    # json data for job
    ]);

    return $pid;
}

sub start {
    my $self = shift;

    $self->{+PID} = $$;

    $0 = "yath-runner-$self->{+NAME}";

    $self->check_delay(
        'BASE',
        $self->{+LAST_EXIT_CODE} ? $self->{+LAST_EXIT} : $self->{+LAST_LAUNCH},
    );

    my $pid = $$;
    my ($ipc, $con) = ipc_connect($self->{+IPC_INFO});

    $self->do_preload($ipc, $con);

    while (1) {
        unless ($$ == $pid) {
            $con = undef;
            $ipc = undef;
            ($ipc, $con) = ipc_connect($self->{+IPC_INFO});
        }

        my $out = $self->run_stage($ipc, $con);
        return $out unless $out && $out->{run_stage};
    }
}

sub check_delay {
    my $self = shift;
    my ($name, $base_time) = @_;

    return unless $base_time;
    my $delta = time - $base_time;

    return 0 unless $delta < $self->{+RETRY_DELAY};
    my $wait = $self->{+RETRY_DELAY} - $delta;

    $0 = "yath-runner-$name-DELAYED";
    print "Stage '$name' reload attempt came too soon, waiting $wait seconds before reloading...\n";
    sleep($wait);
}

sub init {
    my $self = shift;
    $self->{+TREE} //= '';
    $self->{+RETRY_DELAY} //= 5;
}

sub do_preload {
    my $self = shift;
    my ($ipc, $con) = @_;

    my $preloads = $self->{+PRELOADS};

    my $preload;

    $ENV{T2_TRACE_STAMPS} = 1;
    require Test2::API;
    Test2::API::test2_start_preload();
    Test2::API::test2_enable_trace_stamps();

    for my $mod (@$preloads) {
        require(mod2file($mod));
        next unless $mod->can('TEST2_HARNESS_PRELOAD');

        $preload //= Test2::Harness::Preload->new();
        $preload->merge($mod->TEST2_HARNESS_PRELOAD);
    }

    my $stage_data = {BASE => {can_run => []}};

    if ($preload) {
        my $eager  = $preload->eager_stages;
        my $lookup = $preload->stage_lookup;

        for my $stage (keys %$lookup) {
            $stage_data->{$stage} = {
                can_run => $eager->{$stage} // [],
            };
        }
    }

    $con->send_and_get(set_stage_data => $stage_data);

    $self->start_stage($self->{+PARENT}, 'BASE');

    if ($preload) {
        for my $stage (@{$preload->stage_list}) {
            last if $self->fork_stage($stage);
        }
    }

    return;
}

sub fork_stage {
    my $self = shift;
    my ($stage) = @_;

    my $parent = $$;
    my $pid = fork // die "Could not fork: $!";

    if ($pid) {
        $self->{+CHILDREN}->{$pid} = [time, $stage];
        return 0;
    }

    $self->{+PID} = $$;
    $self->{+PARENT} = $parent;
    $self->{+CHILDREN} = {};
    $self->start_stage($parent, $stage);

    for my $child (@{$stage->children || []}) {
        last if $self->fork_stage($child);
    }

    return 1;
}

sub check_children {
    my $self = shift;

    local ($?, $!);

    while (1) {
        my $pid = waitpid(-1, WNOHANG);
        my $exit = $?;

        last if $pid < 1;

        my $set = delete $self->{+CHILDREN}->{$pid} or die "Reaped untracked process!";
        my ($time, $stage) = @$set;

        print "Stage $stage->{name} ended, restarting...\n";

        if ($self->fork_stage($stage)) {
            $self->check_delay($stage->{name}, $time);
            return 1;
        }
    }

    return 0;
}

sub DESTROY {
    my $self = shift;

    return unless $self->{+PID} && $self->{+PID} == $$;

    kill('TERM', keys %{$self->{+CHILDREN}});
}

sub start_stage {
    my $self = shift;
    my ($parent, $stage) = @_;

    $self->{+PARENT} = $parent;

    my $stage_ref = ref($stage);
    my ($name);
    if ($stage_ref) {
        $name = $stage->name;
    }
    else {
        $name = $stage;
    }

    $self->{+STAGE} = $stage;
    $self->{+NAME} = $name;
    my $tree = $self->{+TREE} = $self->{+TREE} ? "$self->{+TREE}-$name" : $name;
    $0 = "yath-runner-$tree";

    $ENV{T2_HARNESS_STAGE} = $name;

    return unless $stage_ref;

    warn "Blacklist, custom require";

    for my $item (@{$stage->load_sequence}) {
        my $type = ref($item);
        if ($type eq 'CODE') {
            $item->();
        }
        else {
            require(mod2file($item));
            die "Cannot load one custom preloader within another" if $item->can('TEST2_HARNESS_PRELOAD');
        }
    }
}

sub terminate {
    my $self = shift;
    my ($reason) = @_;
    $self->{+TERMINATED} = $reason;
}

sub run_stage {
    my $self = shift;
    my ($ipc, $con) = @_;

    my $pid = $$;

    $con->send_and_get(set_stage_up => {stage => $self->{+NAME}, pid => $pid});
    print "Stage '$self->{+NAME}' is up.\n";

    my $guard = Scope::Guard->new(sub {
        return unless $pid == $$;
        $con->send_and_get(set_stage_down => {stage => $self->{+NAME}, pid => $pid}, do_not_respond => 1) if $con && $con->active;
        print "Stage '$self->{+NAME}' is down.\n";
    });

    my $reloader;
    if (my $reloader_class = $self->{+RELOADER}) {
        require(mod2file($reloader_class));
        $reloader = $reloader_class->new(restrict => $self->{+RESTRICT_RELOAD}, stage => $self->{+STAGE});

        $reloader->set_active();
        $reloader->start();
    }

    my $ios = IO::Select->new();
    $ios->add($_) for $ipc->handles_for_select;

    my $exit = 0;
    my $run_spawn;
    my $run_test;
    my $run_stage;

    ipc_loop(
        ipcs      => [$ipc],
        wait_time => 0.2,

        quiet_signals => sub { $self->terminate("SIG" . $_[0]) },

        iteration_start => sub {
            # Check for parent exit
            exit(0) unless pid_is_running($self->{+PARENT});

            # check reload
            if ($reloader && $reloader->check_reload()) {
                $exit = 0;

                no warnings 'exiting';
                last IPC_LOOP;
            }

            # Check kids
            if ($self->check_children()) {
                $run_stage = 1;

                no warnings 'exiting';
                last IPC_LOOP;
            }
        },

        end_check => sub {
            return 1 if $run_test || $run_spawn;
            return 1 if $self->{+TERMINATED};
            return 0;
        },

        handle_request => sub {
            my $req = shift;

            my %prefork_args;
            my $api_call = $req->api_call;

            if ($api_call eq 'launch_job') {
                my $args = $req->args;

                my $ts  = inflate($args->{test_settings}, 'Test2::Harness::TestSettings') or die "No test_settings provided";
                my $run = inflate($args->{run},           'Test2::Harness::Run')          or die "No run provided";
                my $job = inflate($args->{job},           'Test2::Harness::Run::Job')     or die "No job provided";

                %prefork_args = (
                    run           => $run,
                    job           => $job,
                    test_settings => $ts,
                );
            }
            elsif ($api_call eq 'spawn') {
                %prefork_args = (
                    spawn => $req->args,
                );
            }
            else {
                return Test2::Harness::Instance::Response->new(
                    api         => {success => 0, error => "Invalid API call: $api_call."},
                    response_id => $req->request_id,
                    response    => 0,
                );
            }

            $self->do_pre_fork(%prefork_args);

            my $pid = fork // die "Could not fork: $!";

            if ($pid) {
                local $? = 0;
                my $check = waitpid($pid, 0);
                if ($check == $pid && !$?) {
                    return Test2::Harness::Instance::Response->new(
                        api         => {success => 1},
                        response_id => $req->request_id,
                        response    => 1,
                    );
                }
                else {
                    my $x = parse_exit($?);
                    return Test2::Harness::Instance::Response->new(
                        api         => {success => 0, error => "$pid vs $check. exit val: $x->{err} signal: $x->{sig}."},
                        response_id => $req->request_id,
                        response    => 0,
                    );
                }
            }

            if ($api_call eq 'launch_job') {
                $run_test = $req->args;
            }
            elsif ($api_call eq 'spawn') {
                $run_spawn = $req->args;
            }
            else {
                die "Invalid API call: $api_call.\n";
            }

            no warnings 'exiting';
            last IPC_LOOP;
        },

        # Intentionally do nothing.
        handle_message => sub {
            my ($msg) = @_;
            if (my $reason = $msg->{terminate}) {
                $self->terminate($reason);
                POSIX::_exit(0);
            }
        },
    );

    return {run_stage => $run_stage} if $run_stage;
    return {run_test  => $run_test}  if $run_test;
    return {run_spawn => $run_spawn} if $run_spawn;
    return {exit      => $exit};
}

for my $meth (qw/do_pre_fork do_post_fork do_pre_launch/) {
    my $name = $meth;
    my $sub = sub {
        my $self = shift;
        my $stage = $self->stage or return;
        return unless ref($stage);
        $stage->$name(@_);
    };

    no strict 'refs';
    *$meth = $sub;
}

1;

__END__
    my $ipc_map;
    my $ios;
    my $reset_ios = sub {
        $ipc_map = {};
        $ios     = IO::Select->new();
        for my $ipc (@{$self->{+IPC}}) {
            for my $h ($ipc->handles_for_select) {
                $ios->add($h);
                $ipc_map->{$h} = $ipc;
            }
        }
    };
    $reset_ios->();

    my $last_ipc_count = 1;
    my $last_health_check = 0;
    my $advanced = 1;
    while (1) {
        print "LOOP: " . sprintf('%-02.4f', time) . "\n";
        $cb->() if $cb;

        if (time - $last_health_check > 4) {
            $last_ipc_count = 0;

            for my $ipc (@{$self->{+IPC}}) {
                next unless $ipc->active;
                $ipc->health_check;
                $last_ipc_count++ if $ipc->active;
            }

            $last_health_check = time;
        }

        my @ready;
        while (1) {
            $! = 0;
            @ready = $ios->can_read($advanced ? 0 : $self->{+WAIT_TIME});
            last if @ready || $! == 0;

            # If the system call was interrupted it could mean a child process
            # exited, or similar. Just break the loop so we can advance the
            # scheduler which also reaps child processes.
            last if $! == EINTR;

            warn((0 + $!) . ": $!");

            $reset_ios->();
            last unless keys %$ipc_map;
        }

        my %seen;
        for my $h (@ready) {
            my $ipc = $ipc_map->{$h} or next;
            next if $seen{$ipc}++;

            while (my $req = $ipc->get_request) {
                warn "FIXME: Remove these prints" unless $WARNED++;
#                print "Request:  " . encode_pretty_json($req) . "\n";
                my $res = $self->handle_request($req);
#                print "Response: " . encode_pretty_json($res) . "\n";

                next if $req->do_not_respond;

                eval { $ipc->send_response($req, $res); 1 } or ipc_warn(ipc_class => ref($ipc), error => $@, request => $req, response => $res);
            }
        }

        $advanced = $self->{+SCHEDULER}->advance();

        # No IPC means nothing to do
        last unless keys %$ipc_map;
        last unless $last_ipc_count;
        last if $self->{+TERMINATED};
    }


