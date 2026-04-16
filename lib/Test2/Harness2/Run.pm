package Test2::Harness2::Run;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Time::HiRes qw/time/;
use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Run::Job;

use Test2::Harness2::Util::HashBase qw{
    <run_id
    <jobs
    <created_at
    <pending
    <running
    <done
};

sub init {
    my $self = shift;

    $self->{+RUN_ID}     //= gen_uuid();
    $self->{+JOBS}       //= [];
    $self->{+CREATED_AT} //= time;
    $self->{+PENDING}    //= [map { $_->job_id } @{$self->{+JOBS}}];
    $self->{+RUNNING}    //= [];
    $self->{+DONE}       //= [];
}

sub from_files {
    my ($class, %params) = @_;

    my $files = $params{files} or croak "'files' is required";
    croak "'files' must be an arrayref" unless ref($files) eq 'ARRAY';

    my $run_id = $params{run_id} // gen_uuid();

    my @jobs = map {
        Test2::Harness2::Run::Job->new(
            test_file => $_,
            run_id    => $run_id,
        );
    } @$files;

    return $class->new(%params, run_id => $run_id, jobs => \@jobs);
}

sub mark_running {
    my ($self, $jid) = @_;
    my @new = grep { $_ ne $jid } @{$self->{+PENDING}};
    croak "job_id '$jid' is not pending" if @new == @{$self->{+PENDING}};
    $self->{+PENDING} = \@new;
    push @{$self->{+RUNNING}} => $jid;
}

sub mark_done {
    my ($self, $jid) = @_;
    my @new = grep { $_ ne $jid } @{$self->{+RUNNING}};
    croak "job_id '$jid' is not running" if @new == @{$self->{+RUNNING}};
    $self->{+RUNNING} = \@new;
    push @{$self->{+DONE}} => $jid;
}

sub is_complete {
    my $self = shift;
    return !@{$self->{+PENDING}} && !@{$self->{+RUNNING}};
}

1;
