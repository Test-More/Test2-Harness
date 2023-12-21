package Test2::Harness::Run::Job;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use Test2::Harness::TestFile;

use Test2::Harness::Util qw/clean_path/;
use Test2::Harness::Util::UUID qw/gen_uuid/;

use Test2::Harness::Util::HashBase qw{
    <test_file
    <job_id
    <results
    running
};

sub init {
    my $self = shift;

    $self->{+RUNNING} = 0;

    $self->{+JOB_ID} //= gen_uuid();

    my $tf = $self->{+TEST_FILE} or croak "'test_file' is a required field";

    $self->{+RESULTS} //= [];

    $self->{+TEST_FILE} = Test2::Harness::TestFile->new($tf)
        unless blessed($tf);
}

sub try {
    my $self = shift;
    return scalar(@{$self->{+RESULTS}});
}

sub resource_id {
    my $self = shift;
    my $job_id = $self->{+JOB_ID};
    my $try = $self->try // 0;
    return "${job_id}:${try}";
}

sub launch_command {
    my $self = shift;
    my ($run, $ts) = @_;

    my $run_file = $ts->ch_dir ? $self->test_file->file : $self->test_file->relative;

    if ($self->test_file->non_perl) {
        return [$run_file, @{$ts->args // []}];
    }

    my @includes = map { "-I" . clean_path($_) } @{$ts->includes};
    my @loads = map { "-m$_" } @{$ts->load};

    my $load_import = $ts->load_import;
    my @imports;
    for my $mod (@{$load_import->{'@'} // []}) {
        my $args = $load_import->{$mod} // [];

        if ($args && @$args) {
            push @imports => "-M$mod=" . join(',' => @$args);
        }
        else {
            push @imports => "-M$mod";
        }
    }

    return [
        $^X,
        @{$ts->switches // []},
        @includes,
        @imports,
        @loads,
        $run_file,
        @{$ts->args // []},
    ];
}

sub TO_JSON {
    my $self = shift;
    my $class = blessed($self);

    return {
        %$self,
        job_class => $class,
    };
}

sub process_info {
    my $self = shift;

    my $out = $self->TO_JSON;

    delete $out->{+TEST_FILE};
    delete $out->{+RESULTS};

    delete $out->{$_} for grep { m/^_/ } keys %$out;

    return $out;
}

1;
