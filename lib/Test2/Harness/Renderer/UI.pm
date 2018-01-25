package Test2::Harness::Renderer::UI;
use strict;
use warnings;

use Carp qw/croak/;
use Test2::Harness::Util::JSON qw/encode_json encode_pretty_json/;

use POSIX;

BEGIN { require Test2::Harness::Renderer; our @ISA = ('Test2::Harness::Renderer') }
use Test2::Harness::Util::HashBase qw{
    -batch_size
    -buffer

    -url -socket -file

    -api_key -feed -permissions
};

sub init {
    my $self = shift;

    $self->{+BATCH_SIZE} ||= 1000;

    croak "one of 'socket', 'url', or 'file' is required"
        unless $self->{+URL} || $self->{+SOCKET} || $self->{+FILE};

    croak "Invalid socket '$self->{+SOCKET}'"
        if $self->{+SOCKET} && ! -S $self->{+SOCKET};

    croak "An 'api_key' is required"
        unless $self->{+API_KEY};

    croak "file '$self->{+FILE}' already exists"
        if $self->{+FILE} && -e $self->{+FILE};
}

sub render_event {
    my $self = shift;
    my ($event) = @_;
    push @{$self->{+BUFFER}} => $event;

    $self->flush if @{$self->{+BUFFER}} >= $self->{+BATCH_SIZE};
}

sub finish { shift->flush }

sub flush {
    my $self = shift;

    my $events = delete $self->{+BUFFER} or return;
    return unless @$events;

    my $data = {
        api_key     => $self->{+API_KEY},
        permissions => $self->{+PERMISSIONS} || 'private',
        events      => $events,
    };

    if (my $file = $self->{+FILE}) {
        open(my $fh, '>>', $file) or die "Could not open file '$file' for appending: $!";
        print $fh encode_pretty_json($data);
    }

    if (my $sock = $self->{+SOCKET}) {
        die "No socket support yet";
        die "Remember to save the feed id if we do not have one";
    }

    if (my $sock = $self->{+URL}) {
        die "No url support yet";
        die "Remember to save the feed id if we do not have one";
    }
}

1;
