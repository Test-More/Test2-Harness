package Test2::Harness::Runner;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use Test2::Harness::Util qw/parse_exit/;
use Test2::Harness::IPC::Util qw/start_collected_process/;

use Test2::Harness::TestSettings;

use Test2::Harness::Util::HashBase qw{
    <test_settings
    <terminated
    <workdir
};

sub ready { 1 }

sub init {
    my $self = shift;

    croak "'workdir' is a required attribute" unless $self->{+WORKDIR};

    my $ts = $self->{+TEST_SETTINGS} or croak "'test_settings' is a required attribute";
    unless (blessed($ts)) {
        my $class = delete $ts->{class} // 'Test2::Harness::TestSettings';
        $self->{+TEST_SETTINGS} = $class->new(%$ts);
    }
}

sub stages { ['NONE'] }
sub stage_sets { [['NONE', 'NONE']] }

sub job_stage { 'NONE' }

sub start { }

sub abort {}
sub kill {}

sub job_update { }

sub job_launch_data {
    my $self = shift;
    my ($run, $job, $env, $skip) = @_;

    my $run_id = $run->{run_id};

    my $ts = Test2::Harness::TestSettings->merge(
        $self->{+TEST_SETTINGS},
        $run->test_settings,
        $job->test_file->test_settings
    );

    my $env_ref = $ts->env_vars;
    %$env_ref = (%$env_ref, %$env);

    my $workdir = $self->{+WORKDIR};

    return (
        workdir       => $self->{+WORKDIR},
        run           => $run->data_no_jobs,
        skip          => $skip,
        job           => $job,
        test_settings => $ts,
        root_pid      => $$,
        setsid        => 1,
    );
}

sub skip_job {
    my $self = shift;
    my ($run, $job, $env, $skip) = @_;

    $skip //= "Unknown reason";

    return 1 if eval { start_collected_process($self->job_launch_data($run, $job, $env, $skip)); 1 };
    warn $@;
    return 0;
}

sub launch_job {
    my $self = shift;
    my ($stage, $run, $job, $env) = @_;

    croak "Invalid stage '$stage'" unless $stage eq 'NONE';

    return 1 if eval { start_collected_process($self->job_launch_data($run, $job, $env)); 1 };
    warn $@;
    return 0;
}

sub terminate {
    my $self = shift;
    my ($reason) = @_;

    $reason ||= 1;

    return $self->{+TERMINATED} ||= $reason;
}

sub DESTROY {
    my $self = shift;

    $self->terminate('DESTROY');
}

1;
