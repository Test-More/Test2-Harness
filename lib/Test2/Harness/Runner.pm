package Test2::Harness::Runner;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use Test2::Harness::Util qw/parse_exit/;
use Test2::Harness::IPC::Util qw/start_process/;
use Test2::Harness::Util::JSON qw/encode_json/;

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
    my ($run, $job) = @_;

    my $run_id = $run->{run_id};

    my $ts = Test2::Harness::TestSettings->merge(
        $self->{+TEST_SETTINGS},
        $run->test_settings,
        $job->test_file->test_settings
    );

    my $workdir = $self->{+WORKDIR};

    return {
        workdir       => $self->{+WORKDIR},
        run           => $run->data_no_jobs,
        job           => $job,
        test_settings => $ts,
        root_pid      => $$,
    };
}

sub launch_job {
    my $self = shift;
    my ($stage, $run, $job) = @_;

    croak "Invalid stage '$stage'" unless $stage eq 'NONE';

    my %seen;
    my $pid = start_process(
        $^X,                                                                     # Call current perl
        (map { ("-I$_") } grep { -d $_ && !$seen{$_}++ } @INC),                  # Use the dev libs specified
        '-mTest2::Harness::Collector',                                           # Load Collector
        '-e' => 'exit(Test2::Harness::Collector->collect(json => $ARGV[0]))',    # Run it.
        encode_json($self->job_launch_data($run, $job)),                         # json data for job
    );

    local $? = 0;
    my $check = waitpid($pid, 0);
    my $exit  = $?;
    if ($exit || $check != $pid) {
        my $x = parse_exit($exit);
        warn "Collector failed ($check vs $pid) (Exit code: $x->{err}, Signal: $x->{sig})";
        return -1;
    }

    return 1;
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
