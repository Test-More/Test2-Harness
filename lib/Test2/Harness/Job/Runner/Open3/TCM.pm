package Test2::Harness::Job::Runner::Open3::TCM;
use strict;
use warnings;

use App::Yath::Util qw/find_yath/;

use parent 'Test2::Harness::Job::Runner::Open3';

sub command_file {
    my $self = shift;
    my ($test) = @_;
    return (
        'find_yath',
        'tcm',
        $test->job->file,
    );
}

1;
