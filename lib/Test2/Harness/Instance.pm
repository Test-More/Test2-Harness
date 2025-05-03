package Test2::Harness::Instance;
use strict;
use warnings;

our $VERSION = '2.000005';

use IO::Select;

use Carp qw/croak/;
use Time::HiRes qw/sleep time/;

use Test2::Harness::Run;

use Test2::Harness::Util qw/mod2file/;
use Test2::Harness::IPC::Util qw/ipc_warn ipc_loop/;
use Test2::Harness::Util::JSON qw/encode_pretty_json/;

use Test2::Harness::Instance::Message;
use Test2::Harness::Instance::Request;
use Test2::Harness::Instance::Response;

use Test2::Harness::Util::HashBase qw{
    +started
    +stop
    <ipc
    <runner
    <scheduler
    <resources
    <plugins

    <log_file

    <terminated
    <cleaned_up

    <wait_time
};

sub stop { $_[0]->{+STOP} = 1 }

sub init {
    my $self = shift;

    $self->{+STARTED} = time;

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

    my $runner    = $self->runner;
    my $scheduler = $self->scheduler;
    $scheduler->start($self->{+IPC});

    my $plugins   = $self->plugins   // [];
    my $resources = $self->resources // [];

    my %args = (instance => $self, scheduler => $scheduler, runner => $runner);
    $_->instance_setup(%args) for @$plugins;

    for my $res (@$resources) {
        $res->setup(%args);
        $res->spawn_process(%args) if $res->spawns_process;
    }

    ipc_loop(
        ipcs      => $self->{+IPC},
        wait_time => $self->{+WAIT_TIME},

        iteration_start => sub {
            $_->tick(type => 'instance') for @$plugins, @$resources;
            return $cb->(@_) if $cb;
            return;
        },

        end_check => sub {
            return 1 if $self->{+TERMINATED};
            return 1 if $runner->terminated;
            return 1 if $scheduler->terminated;
            return 0;
        },

        signals        => sub { $self->terminate("SIG" . $_[0]) },
        iteration_end  => sub { $self->{+SCHEDULER}->advance() ? 1 : 0 },
        handle_request => sub { $self->handle_request(@_) },

        handle_message => sub { },                                   # Intentionally do nothing.
    );

    $_->teardown(%args)          for reverse @$resources;
    $_->instance_teardown(%args) for reverse @$plugins;

    $runner->terminate();
    $scheduler->terminate();

    $_->cleanup(%args)           for @$resources;
    $_->instance_finalize(%args) for @$plugins;

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

sub api_preload_blacklist {
    my $self = shift;
    my ($req, @mods) = @_;

    return $self->runner->blacklist(@mods);
}

sub api_log_file { shift->{+LOG_FILE} }

sub api_ping { "pong" }

sub api_pid { $$ }

sub api_reload {
    my $self = shift;
    my ($req) = @_;

    return $self->runner->reload;
}

sub api_overall_status {
    my $self = shift;
    my ($req) = @_;

    return [
        $self->runner->overall_status,
        $self->scheduler->overall_status,
    ];
}

sub api_process_list {
    my $self = shift;
    my ($req) = @_;

    my @list = $self->process_list();

    return \@list;
}

sub process_list {
    my $self = shift;

    return (
        {pid => $$, type => 'instance', name => 'instance', stamp => $self->{+STARTED}},
        $self->runner->process_list,
        $self->scheduler->process_list,
    );
}

sub api_resources {
    my $self = shift;

    my @out;

    for my $resource (@{$self->{+RESOURCES} // []}) {
        my $status_data = $resource->status_data or next;
        push @out => [ref($resource), $status_data],
    }

    return \@out;
}

sub api_spawn {
    my $self = shift;
    my ($req, %spawn) = @_;

    my $runner = $self->runner;
    die "Runner is not capable of spawning.\n" unless $runner->can('spawn');

    return $runner->spawn(\%spawn);
}

sub api_kill {
    my $self = shift;

    $self->scheduler->kill();
    $self->runner->kill();
    $self->terminate('KILL');

    return 1;
}

sub api_abort {
    my $self = shift;

    $self->scheduler->abort();
    $self->runner->abort();

    return 1;
}

sub api_stop {
    my $self = shift;

    $self->scheduler->stop();
    $self->runner->stop();
    $self->stop();

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
    my $err   = $params{error};

    $self->runner->set_stage_down($stage, $pid, $err);
}

sub api_queue_run {
    my $self = shift;
    my ($req, %run_data) = @_;

    die "This runner has been terminated" if $self->{+TERMINATED};
    die "This runner has been stopped"    if $self->{+STOP};

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
        $self->scheduler->terminate($self->{+TERMINATED}) if $self->scheduler;
        $self->runner->terminate($self->{+TERMINATED})    if $self->runner;
    }

    return $self->{+TERMINATED};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Instance - FIXME

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

