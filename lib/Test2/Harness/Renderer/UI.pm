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

    -url

    -api_key -feed -permissions
};

sub init {
    my $self = shift;

    $self->{+BATCH_SIZE} ||= 1000;

    croak "'url' is required"
        unless $self->{+URL};

    croak "An 'api_key' is required"
        unless $self->{+API_KEY};
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

    if (my $sock = $self->{+URL}) {
        die "No url support yet";
        die "Remember to save the feed id if we do not have one";
    }
}

1;
