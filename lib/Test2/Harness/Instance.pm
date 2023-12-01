package Test2::Harness::Instance;
use strict;
use warnings;

use IO::Select;

use Carp qw/croak/;
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep time/;

use Test2::Harness::Run;

use Test2::Harness::Util qw/mod2file/;
use Test2::Harness::IPC::Util qw/ipc_warn ipc_loop/;
use Test2::Harness::Util::JSON qw/encode_pretty_json/;

use Test2::Harness::Instance::Message;
use Test2::Harness::Instance::Request;
use Test2::Harness::Instance::Response;

use Test2::Harness::Util::HashBase qw{
    <ipc
    <runner
    <scheduler
    <resources

    <log_file

    <terminated
    <cleaned_up

    <wait_time
};

sub init {
    my $self = shift;

    $self->{+WAIT_TIME} //= 0.2;

    croak "'log_file' is a required attribute" unless $self->{+LOG_FILE};

    my $scheduler = $self->{+SCHEDULER} or croak "'scheduler' is a required attribute";
    my $runner = $self->{+RUNNER} or croak "'runner' is a required attribute";
    $scheduler->set_runner($runner) unless $scheduler->runner;

    croak "'ipc' is a required attribute" unless $self->{+IPC};

    $self->{+IPC} = [$self->{+IPC}] unless ref($self->{+IPC}) eq 'ARRAY';
}

sub run {
    my $self = shift;
    my ($cb) = @_;

    my $scheduler = $self->scheduler;
    $scheduler->start($self->{+IPC});

    for my $res (@{$self->{+RESOURCES} //= []}) {
        next unless $res->spawns_process;
        $res->spawn_process(instance => $self, scheduler => $scheduler);
    }

    ipc_loop(
        ipcs      => $self->{+IPC},
        wait_time => $self->{+WAIT_TIME},

        signals => sub { $self->terminate("SIG" . $_[0]) },

        iteration_start => $cb,
        iteration_end   => sub { $self->{+SCHEDULER}->advance() ? 1 : 0 },
        end_check       => sub { $self->{+TERMINATED}           ? 1 : 0 },

        handle_request => sub { $self->handle_request(@_) },
        handle_message => sub { },                             # Intentionally do nothing.
    );

    $self->{+RUNNER}->terminate();
    $self->{+SCHEDULER}->terminate();

    return;
}

sub handle_request {
    my $self = shift;
    my ($req) = @_;

    my $res;
    unless (eval { $res = $self->_handle_request($req); 1 }) {
        chomp(my $err = $@);

        return Test2::Harness::Instance::Response->new(
            api => {
                success   => 0,
                error     => "There was an exception processing the request",
                exception => $err,
            },
            response_id => $req->request_id,
            response => undef,
        );
    }

    return Test2::Harness::Instance::Response->new(
        api => { success   => 1 },
        response_id => $req->request_id,
        response => $res,
    );
}

sub _handle_request {
    my $self = shift;
    my ($req) = @_;

    my $api_call = $req->api_call;
    my $args = $req->args;

    my $sub = $self->get_api_sub($api_call);

    my $res = $self->$sub($req, $self->parse_request_args($args));

    return $res;
}

sub parse_request_args {
    my $self = shift;
    my ($args) = @_;

    return unless $args;
    my $ref = ref($args);

    return ($args) unless $ref;
    return @$args if $ref eq 'ARRAY';
    return %$args if $ref eq 'HASH';

    die "Invalid API argument format: ($ref) $args.";
}

sub get_api_sub {
    my $self = shift;
    my ($api_call) = @_;

    # In the future we can add the ability for plugins to register new api
    # calls. For now just look for api_XXX methods.
    my $meth = "api_${api_call}";
    return $self->can($meth) // die "'$api_call' is not a valid api call";
}

sub api_log_file { shift->{+LOG_FILE} }

sub api_ping { "pong" }

sub api_pid { $$ }

sub api_kill {
    my $self = shift;

    $self->scheduler->kill();
    $self->runner->kill();
    $self->Terminate('KILL');

    return 1;
}

sub api_abort {
    my $self = shift;

    $self->scheduler->abort();
    $self->runner->abort();

    return 1;
}

sub api_terminate {
    my $self = shift;

    return $self->terminate('API');
}

sub api_set_stage_data {
    my $self = shift;
    my ($req, %stage_data) = @_;

    $self->runner->set_stages(\%stage_data);
}

sub api_set_stage_up {
    my $self = shift;
    my ($req, %params) = @_;

    my $stage = $params{stage} // die "'stage' is required";
    my $pid   = $params{pid} // die "'pid' is required";

    $self->runner->set_stage_up($stage, $pid, $req->connection);
}

sub api_set_stage_down {
    my $self = shift;
    my ($req, %params) = @_;

    my $stage = $params{stage} // die "'stage' is required";
    my $pid   = $params{pid} // die "'pid' is required";

    $self->runner->set_stage_down($stage, $pid);
}

sub api_queue_run {
    my $self = shift;
    my ($req, %run_data) = @_;

    my $run = Test2::Harness::Run->new(%run_data);

    my $agg_ipc = $run->aggregator_ipc;

    my $ipc;
    for my $i (@{$self->{+IPC}}) {
        next unless $i->protocol eq $agg_ipc->{protocol};
        $ipc = $i;
        last;
    }

    if ($ipc) {
        $run->set_ipc($ipc);
    }
    else {
        $ipc = $run->ipc;
        push @{$self->{+IPC}} => $ipc;
    }

    $run->set_instance_ipc($ipc->callback);

    my $con = $run->connect;

    $self->scheduler->queue_run($run);

    return $run->run_id;
}

sub api_job_update {
    my $self = shift;
    my ($req, %update) = @_;

    $self->runner->job_update(\%update);
    $self->scheduler->job_update(\%update);

    return 1;
}

sub DESTROY {
    my $self = shift;
    $self->cleanup;
}

sub cleanup {
    my $self = shift;

    return if $self->{+CLEANED_UP}++;

    $self->terminate('CLEANUP');

    eval { $_->terminate() } for @{$self->{+IPC} // []};
}

sub terminate {
    my $self = shift;
    my ($reason) = @_;

    $reason ||= 1;

    unless ($self->{+TERMINATED}) {
        $self->{+TERMINATED} ||= 1;
        $self->scheduler->terminate($self->{+TERMINATED});
        $self->runner->terminate($self->{+TERMINATED});
    }

    return $self->{+TERMINATED};
}

1;
