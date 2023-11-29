package Test2::Harness::Run::Job;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use Test2::Harness::TestFile;

use Test2::Harness::Util::UUID qw/gen_uuid/;

use Test2::Harness::Util::HashBase qw{
    <test_file
    <job_id
    <results
};

sub init {
    my $self = shift;

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

sub launch_command {
    my $self = shift;
    my ($run, $ts) = @_;

    my @includes = map { "-I$_" } @{$ts->includes};
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
        $self->test_file->file,
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