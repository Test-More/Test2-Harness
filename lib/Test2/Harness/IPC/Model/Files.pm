package Test2::Harness::IPC::Model::Files;
use strict;
use warnings;

our $VERSION = '1.000146';

use Carp qw/croak confess/;

use File::Spec;
use File::Path qw/make_path/;

use Test2::Util qw/get_tid ipc_separator/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;
use Test2::Harness::Util::File::JSONL;
use Test2::Harness::Util::File::Stream;

use parent 'Test2::Harness::IPC::Model';
use Test2::Harness::Util::HashBase qw{
    +render_writer
};

sub get_test_stdout_pair {
    my $self = shift;
    return $self->_get_std_pair(STDOUT => @_);
}

sub get_test_stderr_pair {
    my $self = shift;
    return $self->_get_std_pair(STDERR => @_);
}

sub _get_std_pair {
    my $self = shift;
    my ($fname, $job_id, $job_try) = @_;
    my $workdir = $self->state->workdir;
    my $path = File::Spec->catdir($workdir, $self->{+RUN_ID}, $job_id, $job_try);

    make_path($path) unless -d $path;

    my $file = File::Spec->catfile($path, $fname);

    open(my $wh, '>>', $file) or die "Could not open '$file' for writing: $!";

    my $rs;
    my $read_sub = sub {
        $rs //= Test2::Harness::Util::File::Stream->new(name => $file);
        $rs->poll();
    };

    return ($read_sub, $wh);
}

sub get_test_events_pair {
    my $self = shift;
    my ($job_id, $job_try) = @_;

    my $reader_sub = $self->_generate_reader(event_files => $job_id, $job_try);
    my $writer_sub = $self->_generate_writer(event_files => $job_id, $job_try);

    return ($reader_sub, $writer_sub);
}

sub add_renderer {
    my $self = shift;
    return $self->_generate_reader('render_files');
}

sub render_event {
    my $self = shift;
    my ($e) = @_;
    my $writer = $self->{+RENDER_WRITER} //= $self->_generate_writer('render_files');
    $writer->($e);
}

sub _generate_writer {
    my $self = shift;
    my ($type, @path) = @_;

    my $workdir = $self->state->workdir;
    my $path = File::Spec->catdir($workdir, $self->{+RUN_ID}, @path);
    make_path($path) unless -d $path;

    my ($tid, $pid, $stream, $file) = (0, 0);
    my $writer_sub = sub {
        if ($tid != get_tid() || $pid != $$) {
            $tid = get_tid();
            $pid = $$;
            $file = File::Spec->catfile($path, join(ipc_separator(), time, $pid, $tid) . ".jsonl");
            $stream = Test2::Harness::Util::File::JSONL->new(name => $file);
            $self->{+STATE}->transaction(w => sub {
                my ($state) = @_;
                my $files = $self->_get_file_list($type, $self->{+RUN_ID}, @path);
                push @$files => $file;
            });
        }

        $stream->write($_) for @_;
    };
}

sub _generate_reader {
    my $self = shift;
    my ($type, @path) = @_;

    my $workdir = $self->state->workdir;
    my $path = File::Spec->catdir($workdir, $self->{+RUN_ID}, @path);
    make_path($path) unless -d $path;

    my ($tid, $pid, %streams) = (0, 0);
    my $reader_sub = sub {
        if ($tid != get_tid() || $pid != $$) {
            $tid = get_tid();
            $pid = $$;

            # Clear stream cache on new proc/thread
            %streams = ();
        }

        my @events;

        my $files = $self->_get_file_list($type, $self->{+RUN_ID}, @path);
        for my $file (@$files) {
            my $stream = $streams{$file} //= Test2::Harness::Util::File::JSONL->new(name => $file);
            push @events => $stream->poll();
        }

        return @events;
    };

    return $reader_sub;
}

sub _get_file_list {
    my $self = shift;
    my @path = @_;
    my $last = pop @path;

    my $data = $self->{+STATE}->data->ipc_model;
    $data = $data->{$_} //= {} for @path;
    $data = $data->{$last} //= [];
    return $data;
}

sub finish {
    my $self = shift;
    $self->render_event(undef);
}

1;
