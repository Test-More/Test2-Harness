package Test2::Harness::Run;
use strict;
use warnings;

use Carp qw/croak confess/;
use Scalar::Util qw/blessed/;

use Test2::Harness::TestSettings;
use Test2::Harness::IPC::Protocol;

use Test2::Harness::Util qw/mod2file/;

our $VERSION = '2.000000';

my @NO_JSON;
BEGIN {
    @NO_JSON = qw{
        ipc
        connect
    };

    sub no_json { @NO_JSON }
}

use Test2::Harness::Util::HashBase(
    # From Options::Run
    qw{
        <links
        <test_args
        <input
        <input_file
        <dbi_profiling
        <author_testing
        <stream
        <fields
        <run_id
        <event_uuids
        <mem_usage
        <retry
        <retry_isolated
        <abort_on_bail
        <nytprof
    },

    qw{
        instance_ipc
        <aggregator_ipc
        <jobs
        <job_lookup
        <test_settings
    },

    (map { "+$_" } @NO_JSON),
);

sub init {
    my $self = shift;

    croak "'run_id' is a required attribute" unless $self->{+RUN_ID};

    my $ts = $self->{+TEST_SETTINGS} or croak "'test_settings' is a required attribute";
    unless (blessed($ts)) {
        my $class = delete $ts->{class} // 'Test2::Harness::TestSettings';
        $self->{+TEST_SETTINGS} = $class->new(%$ts);
    }

    if (my $jobs = $self->{+JOBS}) {
        my (@jobs, %jobs);
        for my $job (@$jobs) {
            my $class = $job->{job_class} // 'Test2::Harness::Run::Job';
            require(mod2file($class));
            my $jo = $class->new(%$job);
            push @jobs => $jo;
            $jobs{$jo->job_id} = $jo;
        }
        $self->{+JOBS} = \@jobs;
        $self->{+JOB_LOOKUP} = \%jobs;
    }

    croak "'aggregator_ipc' is a required attribute" unless $self->{+AGGREGATOR_IPC};
}

sub set_ipc { $_[0]->{+IPC} = $_[1] }
sub ipc {
    my $self = shift;
    return $self->{+IPC} if $self->{+IPC};

    my $agg_ipc = $self->{+AGGREGATOR_IPC};
    return $self->{+IPC} = Test2::Harness::IPC::Protocol->new(protocol => $agg_ipc->{protocol});
}

sub set_connect { $_[0]->{+CONNECT} = $_[1] }
sub connect {
    my $self = shift;
    return $self->{+CONNECT} if $self->{+CONNECT};

    my $agg_ipc = $self->{+AGGREGATOR_IPC};
    return $self->{+CONNECT} = $self->ipc->connect(@{$agg_ipc->{connect}});
}

sub data_no_jobs {
    my $self = shift;

    my %data = %$self;
    delete $data{$_} for $self->no_json, 'jobs';

    return \%data;
}

sub TO_JSON {
    my $self = shift;

    my %data = %$self;
    delete $data{$_} for $self->no_json;

    return \%data;
}

1;
