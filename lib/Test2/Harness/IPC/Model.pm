package Test2::Harness::IPC::Model;
use strict;
use warnings;

our $VERSION = '1.000146';

use Carp qw/croak confess/;
use Scalar::Util qw/blessed/;

use Test2::Harness::Util::HashBase qw{
    <state <pid <run_id
};

sub init {
    my $self = shift;

    $self->{+PID} //= $$;
    croak "'state' is required"  unless $self->{+STATE};
    croak "'run_id' is required" unless $self->{+RUN_ID};
}

sub establish_interactive_stdin {
    my $self = shift;

    my $fh;

    if (my $fifo = $ENV{YATH_INTERACTIVE}) {
        open($fh, '<', $fifo) or die "Could not open fifo '$fifo': $!";
    }
    elsif (-t STDIN) {
        $fh = \*STDIN;
    }
    else {
        confess "No human input source is available";
    }

    return $fh;
}

sub get_test_stdout_pair { croak(blessed($_[0]) . '->get_test_stdout_pair() is not implemented') }
sub get_test_stderr_pair { croak(blessed($_[0]) . '->get_test_stderr_pair() is not implemented') }
sub get_test_events_pair { croak(blessed($_[0]) . '->get_test_events_pair() is not implemented') }
sub add_renderer         { croak(blessed($_[0]) . '->add_renderer() is not implemented')         }
sub render_event         { croak(blessed($_[0]) . '->render_event() is not implemented')         }

sub finish {}

1;
