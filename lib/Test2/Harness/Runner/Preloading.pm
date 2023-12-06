package Test2::Harness::Runner::Preloading;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak confess/;
use Scalar::Util qw/blessed/;

use Test2::Util qw/IS_WIN32/;

use Test2::Harness::Util qw/parse_exit mod2file/;
use Test2::Harness::Util::JSON qw/encode_json/;

use Test2::Harness::Preload();
use Test2::Harness::TestSettings;
use Test2::Harness::Runner::Preloading::Stage;

use parent 'Test2::Harness::Runner';
use Test2::Harness::Util::HashBase qw{
    +stages
    <preloads
    <default_stage
    <preload_retry_delay
    <reloader
    <restrict_reload
};

sub init {
    my $self = shift;

    die "The PRELOAD runner is not usable on Windows.\n" if IS_WIN32;

    $self->SUPER::init();

    $self->{+STAGES} = undef;

    $self->{+PRELOAD_RETRY_DELAY} //= 5;
}

sub ready { $_[0]->{+STAGES} ? 1 : 0 }

sub set_stages {
    my $self = shift;
    my ($data) = @_;

    $data->{NONE}->{ready} = {pid => undef, con => undef};
    $data->{NONE}->{can_run} //= [];

    $self->{+STAGES} = $data;
}

sub stages {
    my $self = shift;

    return $self->{+STAGES} // confess "No stage data yet";
}

sub set_stage_up {
    my $self = shift;
    my ($stage, $pid, $con) = @_;

    my $stage_data = $self->stages->{$stage} // die "Invalid stage '$stage'";
    $stage_data->{ready} = {pid => $pid, con => $con};

    return $pid;
}

sub set_stage_down {
    my $self = shift;
    my ($stage, $pid) = @_;

    my $stage_data = $self->stages->{$stage} // die "Invalid stage '$stage'";
    my $ready = $stage_data->{ready} // die "Stage not ready '$stage'";

    if ($pid && $ready->{pid}) {
        # It is possible we got the 'down' after a new 'up'
        if ($ready->{pid} == $pid) {
            delete $stage_data->{ready};
        }
    }
    else {
        delete $stage_data->{ready};
    }

    return 1;
}

sub stage_sets {
    my $self = shift;

    my $stages = $self->stages;

    my %sets;

    for my $stage (keys %$stages) {
        my $sdata = $stages->{$stage};
        my $ready = $sdata->{ready} or next;
        if (ref($ready)) {
            next unless $ready->{con};
            next unless $ready->{pid};
        }

        $sets{$stage} = $stage;
        $sets{$_} //= $stage for @{$sdata->{can_run} // []};
    }

    return [ map { [$_ => $sets{$_}] } keys %sets ];
}

sub DESTROY { shift->terminate }

sub terminate {
    my $self = shift;

    $self->SUPER::terminate(@_);

    kill('TERM', grep { $_ } map { $_->{ready}->{pid} // () } values %{$self->stages});
}

sub kill {
    my $self = shift;
    $self->terminate;
}

sub job_stage {
    my $self = shift;
    my ($job, $stage_request) = @_;

    my $stages = $self->stages;

    return 'NONE' unless $self->{+PRELOADS} && @{$self->{+PRELOADS}};

    for my $s ($stage_request, $self->default_stage, 'BASE') {
        next unless $s;
        next unless $stages->{$s};
        return $s;
    }

    confess "No valid stages!";
}

sub start {
    my $self = shift;
    my ($scheduler, $ipc) = @_;

    my $ts = $self->{+TEST_SETTINGS};

    my $preloads = $self->{+PRELOADS} or return;
    return unless @$preloads;

    $self->start_base_stage($scheduler, $ipc);
}

sub start_base_stage {
    my $self = shift;
    my ($scheduler, $ipc, $last_launch, $last_exit, $exit_code) = @_;

    print "Launching 'BASE' stage.\n";

    my $pid = Test2::Harness::Runner::Preloading::Stage->launch(
        name            => 'BASE',
        test_settings   => $self->{+TEST_SETTINGS},
        ipc_info        => $ipc->[0]->callback,
        preloads        => $self->preloads,
        retry_delay     => $self->{+PRELOAD_RETRY_DELAY},
        last_launch     => $last_launch,
        last_exit       => $last_exit,
        last_exit_code  => $exit_code,
        reloader        => $self->{+RELOADER},
        restrict_reload => $self->{+RESTRICT_RELOAD},
        root_pid        => $$,
    );

    my $launched = time;
    $scheduler->register_child(
        $pid => sub {
            my %params = @_;

            my $exit      = $params{exit};
            my $scheduler = $params{scheduler};

            my $x = parse_exit($exit);
            print "Stage 'BASE' exited(sig: $x->{sig}, code: $x->{err}).\n";

            return if $scheduler->terminated || $scheduler->runner->terminated;

            $scheduler->runner->start_base_stage($scheduler, $ipc, $launched, time, $x->{err});
        },
    );
}

sub launch_job {
    my $self = shift;
    my ($stage, $run, $job, $env) = @_;

    my %job_launch_data = $self->job_launch_data($run, $job, $env);
    my $ts = $job_launch_data{test_settings};

    my $can_fork = 1;
    $can_fork &&= $stage ne 'NONE';
    $can_fork &&= $ts->use_fork;
    $can_fork &&= $ts->use_preload;

    return $self->SUPER::launch_job('NONE', $run, $job) unless $can_fork;

    my $stage_data = $self->stages->{$stage} or confess "Invalid stage: '$stage'";

    my $res = $stage_data->{ready}->{con}->send_and_get(launch_job => \%job_launch_data);
    return 1 if $res->success;
}

1;
