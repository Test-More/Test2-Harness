use Test2::V0;

__END__

package Test2::Harness::Runner::Run;
use strict;
use warnings;

our $VERSION = '0.001100';

use Carp qw/croak/;
use File::Spec();

use Test2::Harness::Util::File::JSONL;

use parent 'Test2::Harness::Run';
use Test2::Harness::Util::HashBase qw{
    <workdir

    +queue
    >queue_ended
    +queue_pid

    +run_dir
    +jobs_file
    +jobs
};

sub init {
    my $self = shift;

    $self->SUPER::init();

    croak "'workdir' is a required attribute" unless $self->{+WORKDIR};
}

sub run_dir   { $_[0]->{+RUN_DIR}   //= $_[0]->SUPER::run_dir($_[0]->{+WORKDIR}) }
sub jobs_file { $_[0]->{+JOBS_FILE} //= File::Spec->catfile($_[0]->run_dir, 'jobs.jsonl') }
sub jobs      { $_[0]->{+JOBS}      //= Test2::Harness::Util::File::JSONL->new(name => $_[0]->jobs_file, use_write_lock => 1) }

sub _check_queue {
    my $self = shift;

    my $queue = $self->{+QUEUE} or return;

    return if $self->{+QUEUE_PID} && $self->{+QUEUE_PID} == $$;

    delete $self->{+QUEUE_ENDED};
    $queue->reset;
    $self->{+QUEUE_PID} = $$;
}

sub queue {
    my $self = shift;

    $self->_check_queue();

    return $self->{+QUEUE} if $self->{+QUEUE};

    $self->{+QUEUE_PID} = $$;
    return $self->{+QUEUE} = $self->SUPER::queue($self->run_dir);
}

sub queue_ended {
    my $self = shift;
    $self->_check_queue();
    return $self->{+QUEUE_ENDED};
}

1;
