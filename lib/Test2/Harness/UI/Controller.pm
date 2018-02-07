package Test2::Harness::UI::Controller;
use strict;
use warnings;

use Carp qw/croak/;

use Test2::Harness::UI::Util::HashBase qw/-request -config -schema/;

sub init {
    my $self = shift;

    croak "The 'config' attribute is required"  unless $self->{+CONFIG};
    croak "The 'request' attribute is required" unless $self->{+REQUEST};

    $self->{+SCHEMA} ||= $self->{+CONFIG}->schema;
}

sub do_once {}

sub process {
    my $self = shift;

    $self->do_once;

    my ($content, $headers) = $self->process_request();

    $headers ||= [];

    push @$headers => $self->add_headers;

    $content = $self->wrap_content($content);

    return ($content, $headers);
}

sub wrap_content { $_[1] }

sub add_headers {}

1;
