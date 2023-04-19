package Test2::Harness::Aggregator;
use strict;
use warnings;

use Carp qw/croak/;
use POSIX qw/mkfifo/;

use Test2::Harness::Util::JSON qw/encode_json/;

use Atomic::Pipe;
use Test2::Harness::Util::File::Stream;

our $VERSION = '2.000000';

use Test2::Harness::Util::HashBase qw{
    -fifo_file
    -output_file
    -state
    -name
};

sub init {
    my $self = shift;

    croak "'name' is a required attribute"        unless $self->{+NAME};
    croak "'fifo_file' is a required attribute"   unless $self->{+FIFO_FILE};
    croak "'output_file' is a required attribute" unless $self->{+OUTPUT_FILE};
    croak "'state' is a required attribute"       unless $self->{+STATE};
}

sub run {
    my $self = shift;
    my ($parent_pid) = @_;

    my $outfh = Test2::Harness::Util::File::Stream->new(name => $self->{+OUTPUT_FILE});
    $outfh->write();    # Touch the file

    my $sig = 0;

    my $ok = eval {
        $SIG{__WARN__} = sub {
            print STDERR @_;
            $outfh->write(encode_json({
                facet_data => {
                    info => [
                        {tag => 'AGG WARN', details => "(AGGREGATOR) " . join ' ' => @_},
                    ],
                }
            }) . "\n");
        };

        my $fifo;

        local $SIG{INT} = sub {
            print STDERR "Aggregator ($self->{+NAME}) Got SIGINT\n";
            $sig = 'INT';
            $fifo->blocking(0) if $fifo;
        };

        local $SIG{TERM} = sub {
            print STDERR "Aggregator ($self->{+NAME}) Got SIGTERM\n";
            $sig = 'TERM';
            $fifo->blocking(0) if $fifo;
        };

        mkfifo($self->{+FIFO_FILE}, 0700) or die "Failed to create fifo ($self->{+FIFO_FILE}): $!";

        $fifo = Atomic::Pipe->read_fifo($self->{+FIFO_FILE});
        $fifo->resize($fifo->max_size);

        $self->{+STATE}->transaction(
            w => sub {
                my ($state, $data) = @_;
                $data->aggregators->{$self->{+NAME}} = {
                    pid    => $$,
                    name   => $self->{+NAME},
                    fifo   => $self->{+FIFO_FILE},
                    output => $self->{+OUTPUT_FILE},
                };

                $data->processes->{$$} = {type => 'aggregator', parent => $parent_pid, pid => $$, name => $self->{+NAME}};
            }
        );

        while (1) {
            $fifo->blocking(0) if $sig;

            my $event = $fifo->read_message;

            if ($sig && !$event) {
                $outfh->write(encode_json({
                    facet_data => {
                        info => [
                            {tag => "AGG  SIG", details => "(AGGREGATOR) got SIG${sig}"},
                        ],
                    }
                }) . "\n");
                $outfh->write("null\n");
                last;
            }

            chomp($event);

            next if $event eq 'null';

            if ($event eq 'TERMINATE') {
                $outfh->write("null\n");
                last;
            }

            $outfh->write("$event\n");
        }

        $self->{+STATE}->transaction(
            w => sub {
                my ($state, $data) = @_;
                delete $data->{aggregators}->{$self->{+NAME}};
                delete $data->processes->{$$};
            },
        );

        1;
    };
    my $err = $@;

    kill($sig, $$) if $sig;

    return 0 if $ok;

    print STDERR $err;
    $outfh->write(encode_json({
        facet_data => {
            info => [
                {tag => 'AGG DIED', details => "(AGGREGATOR) " . join ' ' => @_},
            ],
        }
    }) . "\n");

    return 255;
}
