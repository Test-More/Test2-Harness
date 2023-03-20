package Test2::Harness::IPC::Model::AtomicPipe;
use strict;
use warnings;

our $VERSION = '1.000146';

use Carp qw/croak confess/;
use POSIX qw/mkfifo/;
use File::Path qw/make_path/;

use File::Spec;
use Atomic::Pipe;

use Test2::Util qw/get_tid/;
use Test2::Harness::Util::UUID qw/gen_uuid/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use parent 'Test2::Harness::IPC::Model';
use Test2::Harness::Util::HashBase qw{
    +pair_cache
    +renderer_writers
};

sub _get_mixed_pair {
    my $self = shift;

    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);

    $r->resize($r->max_size);
    $w->resize($w->max_size);
    $w->wh->autoflush(1);

    my %out;

    my (@lines, @data);
    my $read = sub {
        if ($w) {
            $w->close();
            $w = undef;
            delete $out{write_ap};
        }

        while (1) {
            my ($type, $val) = $r->get_line_burst_or_data;
            last unless $type;

            if ($type eq 'message') {
                push @data => decode_json($val);
            }
            elsif ($type eq 'line') {
                push @lines => $val;
            }
            else {
                die "Invalid type '$type'";
            }
        }
    };

    my $read_line = sub { $read->(); my @out = @lines; @lines = (); return @out };
    my $read_data = sub { $read->(); my @out = @data;  @data  = (); return @out };

    %out = (
        read_line => $read_line,
        read_data => $read_data,
        read_ap   => $r,
        write_ap  => $w,
    );

    return \%out;
}

sub get_test_stdout_pair {
    my $self = shift;
    my ($job_id, $job_try) = @_;

    my $bits = $self->{+PAIR_CACHE}->{$job_id}->{$job_try} //= $self->_get_mixed_pair;

    return ($bits->{read_line}, $bits->{write_ap}->wh());
}

sub get_test_stderr_pair {
    my $self = shift;
    my ($r, $w) = Atomic::Pipe->pair;
    $r->resize($r->max_size);
    my $rh = $r->rh;
    $rh->blocking(0);
    $w->resize($w->max_size);
    $w->wh->autoflush(1);
    return (sub { <$rh> }, $w->wh());
}

sub get_test_events_pair {
    my $self = shift;
    my ($job_id, $job_try) = @_;

    my $bits = $self->{+PAIR_CACHE}->{$job_id}->{$job_try} //= $self->_get_mixed_pair;

    my $writer_sub = sub {
        if ($bits->{read_ap}) {
            $bits->{read_ap}->close();
            delete $bits->{read_ap};
            delete $bits->{read_line};
            delete $bits->{read_data};
        }

        $bits->{write_ap}->write_message(encode_json($_)) for @_;
    };

    return ($bits->{read_data}, $writer_sub);
}

sub add_renderer {
    my $self = shift;

    my $workdir = $self->state->workdir;
    my $path = File::Spec->catdir($workdir, $self->{+RUN_ID}, 'renderers');
    make_path($path) unless -d $path;

    # Create file for fifo
    my $id = gen_uuid();
    my $file = File::Spec->catfile($path, "${id}.fifo");

    # make fifo
    mkfifo($file, 0700) or die "Failed to create fifo";

    my $r = Atomic::Pipe->read_fifo($file);
    $r->resize($r->max_size);
    $r->blocking(0);

    # add the fifo to state for future writers
    $self->{+STATE}->transaction(w => sub {
        my ($state, $data) = @_;
        my $files = $data->ipc_model->{render_pipes}->{$self->{+RUN_ID}} //= [];
        push @$files => $file;
    });

    # return a sub to read the fifo
    return sub {
        my @out;
        while (my $msg = $r->read_message) {
            push @out => decode_json($msg);
        }
        return @out;
    };
}

sub renderer_writers {
    my $self = shift;

    if (my $have = $self->{+RENDERER_WRITERS}) {
        return @{$have->{list} //= []} if $have->{pid} == $$ && $have->{tid} == get_tid();
        delete $self->{+RENDERER_WRITERS};
        delete $_->{out_buffer} for @{$have->{list} // []};
    }

    my @list;
    for my $ap (@{$self->{+STATE}->data->ipc_model->{render_pipes}->{$self->{+RUN_ID}} // []}) {
        my $w = Atomic::Pipe->write_fifo($ap);
        $w->resize($w->max_size);
        push @list => $w;
    }

    $self->{+RENDERER_WRITERS} = {
        pid  => $$,
        tid  => get_tid(),
        list => \@list,
    };

    return @list;
}

sub render_event {
    my $self = shift;
    my ($e) = @_;

    my $json = encode_json($e);

    $_->write_message($json) for $self->renderer_writers;
}

sub finish {
    my $self = shift;
    # Blocking flush on all/any renderer handles

    # First flush any that can be flushed without a wait
    $_->flush(blocking => 0) for $self->renderer_writers;

    # Terminate the output
    $self->render_event(undef);

    # Now we wait and flush all.
    for my $ap ($self->renderer_writers) {
        $ap->flush(blocking => 1);
        $ap->close();
    }
}

1;
