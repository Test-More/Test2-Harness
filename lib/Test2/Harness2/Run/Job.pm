package Test2::Harness2::Run::Job;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Util::HashBase qw{
    <job_id
    <test_file
    <job_try
    <run_id
};

sub init {
    my $self = shift;

    croak "'test_file' is a required attribute"
        unless defined $self->{+TEST_FILE};

    croak "'run_id' is a required attribute"
        unless defined $self->{+RUN_ID};

    $self->{+JOB_ID}  //= gen_uuid();
    $self->{+JOB_TRY} //= 0;
}

1;
