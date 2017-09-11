package Test2::Harness::Job::Runner::Open3::TCM;
use strict;
use warnings;

use parent 'Test2::Harness::Job::Runner::Open3';

our $VERSION = '0.001007';

sub command_file {
    my $self = shift;
    my ($test) = @_;
    return (
        $self->find_tcm_script,
        $test->job->file,
    );
}

sub find_tcm_script {
    my $self = shift;

    my $script = $ENV{T2_HARNESS_TCM_SCRIPT} || 'yath-tcm';
    return $script if -f $script;

    if ($0 && $0 =~ m{(.*)\byath(-.*)?$}) {
        return "$1$script" if -f "$1$script";
    }

    # Do we have the full path?
    # Load IPC::Cmd only if needed, it indirectly loads version.pm which really
    # screws things up...
    require IPC::Cmd;
    if(my $out = IPC::Cmd::can_run($script)) {
        return $out;
    }

    die "Could not find '$script' in execution path";
}


1;
