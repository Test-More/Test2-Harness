package Test2::Harness::Scheduler::Run;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'Test2::Harness::Run';

my @NO_JSON;
BEGIN {
    @NO_JSON = qw{
        todo
        running
        complete
    };

    sub no_json {
        my $self = shift;

        return (
            $self->SUPER::no_json(),
            @NO_JSON,
        );
    }
}

use Test2::Harness::Util::HashBase(
    @NO_JSON,
    qw{
        <results
        halt
        pid
    },
);

sub init {
    my $self = shift;

    $self->SUPER::init();

    $self->{+COMPLETE} = [];
    $self->{+RUNNING}  = {};
    $self->{+TODO}     = {};
}

1;
