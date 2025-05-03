package Test2::Harness::Runner::Preloading::Stage;
use strict;
use warnings;

our $VERSION = '2.000005';

my %ORIG_SIG;
BEGIN { %ORIG_SIG = %SIG }

use goto::file();
use Scope::Guard;

use Time::HiRes qw/time/;
use POSIX qw/:sys_wait_h ceil/;

use Test2::Harness::Util qw/mod2file parse_exit/;
use Test2::Harness::IPC::Util qw/start_process ipc_connect ipc_warn ipc_loop pid_is_running inflate set_procname/;
use Test2::Harness::Util::JSON qw/decode_json encode_json/;

use Test2::Harness::Collector::Preloaded;

use Test2::Harness::Util::HashBase qw{
    <test_settings
    <name
    <tree
    <preloads
    <retry_delay
    <stage

    <reloader
    <reload_in_place
    <restrict_reload

    <pid <parent <root_pid

    <last_launch
    <last_exit
    <last_exit_code

    <children
    <terminated
    <is_daemon
    <bad

    <ipc_info
    +ipc +ipc_con +ipc_pid
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

sub ipc {
    my $self = shift;

    return unless $self->{+IPC_INFO};

    if (my $ipc_pid = $self->{+IPC_PID}) {
        if ($ipc_pid != $$) {
            delete $self->{+IPC};
            delete $self->{+IPC_CON};
            delete $self->{+IPC_PID};
        }
    }

    unless ($self->{+IPC} && $self->{+IPC_CON} && $self->{+IPC_PID}) {
        $self->{+IPC_PID} = $$;
        ($self->{+IPC}, $self->{+IPC_CON}) = ipc_connect($self->{+IPC_INFO});
    }

    return ($self->{+IPC}, $self->{+IPC_CON});
}

sub start {
    my $self = shift;

    $self->{+PID} = $$;

    set_procname(set => ['runner', $self->{+NAME}]);

    $self->check_delay(
        'BASE',
        $self->{+LAST_EXIT_CODE} ? $self->{+LAST_EXIT} : $self->{+LAST_LAUNCH},
    );

    my ($ipc, $con) = $self->ipc;

    $self->do_preload();

    my $count = 0;
    my ($ok, $err) = (1, '');
    while (1) {
        ($ipc, $con) = $self->ipc;

        unless($ok) {
            eval { $con->send_and_get(set_stage_down => {stage => $self->{+NAME}, pid => $$, error => $err}); 1 } or warn $@;
            die $err;
        }

        my $out;
        $ok = eval { $out = $self->run_stage; 1 };
        chomp($err = $@);

        next unless $ok;
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

    set_procname(set => ['runner', $self->{+NAME}, 'DELAYED']);
    print "Stage '$name' reload attempt came too soon, waiting " . ceil($wait) . " seconds before reloading...\n";
    sleep($wait);
}

sub init {
    my $self = shift;
    $self->{+TREE} //= '';
    $self->{+RETRY_DELAY} //= 5;
}

sub do_preload {
    my $self = shift;
    my ($ipc, $con) = $self->ipc;

    my $preloads = $self->{+PRELOADS};

    my $preload;

    $ENV{T2_TRACE_STAMPS} = 1;
    require Test2::API;
    Test2::API::test2_start_preload();
    Test2::API::test2_enable_trace_stamps();

    for my $mod (@$preloads) {
        unless (eval { require(mod2file($mod)); 1 }) {
            die $@ unless $self->is_daemon;
            print STDERR "Base stage failed to load $mod: $@";
            $self->{+BAD} = time;
            next;
        }
        next unless $mod->can('TEST2_HARNESS_PRELOAD');

        $preload //= Test2::Harness::Preload->new();
        $preload->merge($mod->TEST2_HARNESS_PRELOAD);
    }

    my $stage_data = {BASE => {can_run => []}};

    if ($preload) {
        my $eager  = $preload->eager_stages;
        my $lookup = $preload->stage_lookup;
        my $default = $preload->default_stage // '';

        for my $stage (keys %$lookup) {
            $stage_data->{$stage} = {
                can_run => $eager->{$stage} // [],
                default => $stage eq $default ? 1 : 0,
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
    my ($stage, $check_delay) = @_;

    my $parent = $$;
    my $pid = fork // die "Could not fork: $!";

    if ($pid) {
        my $time = time;
        $time += $self->{+RETRY_DELAY} if $check_delay;
        $self->{+CHILDREN}->{$pid} = [$time, $stage];
        return 0;
    }

    $self->check_delay($stage->{name}, $check_delay)
        if defined $check_delay;

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

    my @todo;

    while (1) {
        my $pid = waitpid(-1, WNOHANG);
        my $exit = $?;

        last if $pid < 1;

        my $set = delete $self->{+CHILDREN}->{$pid} or die "Reaped untracked process!";
        push @todo => [$pid, @$set];
    }

    for my $set (@todo) {
        my ($pid, $time, $stage) = @$set;

        if ($self->is_daemon) {
            print "[$pid] Stage '$stage->{name}' ended, restarting...\n";
            return 1 if $self->fork_stage($stage, $time);
        }
        else {
            print "[$pid] Stage '$stage->{name}' ended...\n";
            exit(1);
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

    local $Test2::Harness::Runner::Preloading::Stage::ACTIVE;

    my $stage_ref = ref($stage);
    my ($name);
    if ($stage_ref) {
        $Test2::Harness::Runner::Preloading::Stage::ACTIVE = $stage;
        $name = $stage->name;
    }
    else {
        $name = $stage;
    }

    $self->{+STAGE} = $stage;
    $self->{+NAME} = $name;
    my $tree = $self->{+TREE} = $self->{+TREE} ? "$self->{+TREE}-$name" : $name;
    set_procname(set => ['runner', $tree]);

    $ENV{T2_HARNESS_STAGE} = $name;

    return unless $stage_ref;

    my ($ipc, $con) = $self->ipc;
    my $blacklist = $con->send_and_get('preload_blacklist')->response;

    for my $item (@{$stage->load_sequence}) {
        my $type = ref($item);
        if ($type eq 'CODE') {
            $item->();
        }
        else {
            next if $blacklist->{$item};
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

    my $pid = $$;
    my ($ipc, $con) = $self->ipc;

    $con->send_and_get(set_stage_up => {stage => $self->{+NAME}, pid => $pid});
    print "[$$] Stage '$self->{+NAME}' is up.\n";

    my $guard = Scope::Guard->new(sub {
        return unless $pid == $$;
        my $ok = eval { $con->send_and_get(set_stage_down => {stage => $self->{+NAME}, pid => $pid}, do_not_respond => 1) if $con && $con->active; 1 };
        die $@ unless $ok || $@ =~ m/Disconnected pipe/;
        print "[$$] Stage '$self->{+NAME}' is down.\n";
    });

    my $reloader;
    if (my $reloader_class = $self->{+RELOADER}) {
        require(mod2file($reloader_class));
        $reloader = $reloader_class->new(restrict => $self->{+RESTRICT_RELOAD}, stage => $self->{+STAGE}, in_place => $self->{+RELOAD_IN_PLACE});

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
            if ($reloader) {
                # Returns undef if all is good
                # Returns an arrayref if there is an issue
                # Arrayref is a list of failed modules, but may be empty if it is a non-module that needs reload.
                my $cannot_load = $reloader->check_reload();

                if ($cannot_load) {
                    $exit = 0;

                    if (@$cannot_load) {
                        print STDERR "$$ $0 - Blacklisting $_...\n" for @$cannot_load;
                        $con->send_and_get(preload_blacklist => $cannot_load)
                    }

                    no warnings 'exiting';
                    last IPC_LOOP;
                }
            }

            # Check kids
            if ($self->check_children()) {
                $run_stage = 1;

                no warnings 'exiting';
                last IPC_LOOP;
            }
        },

        end_check => sub {
            if ($self->{+BAD} && (time - $self->{+BAD}) > 60) {
                print STDERR "60 seconds have elapsed since preload failure, exiting for reload...\n";
                $exit = 255;
                return 1;
            }
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

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Preloading::Stage - FIXME

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

