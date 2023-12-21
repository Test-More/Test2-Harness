package Test2::Harness;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Test2::Harness::Util::HashBase;

sub init {
    my $self = shift;
}

sub ipc { croak "ipc() is not implemented" };
sub connect { croak "connect() is not implemented" };

sub ping {
    my $self = shift;
    my ($args) = @_;

    return $self->send_and_get(ping => $args);
}

sub queue_run {
    my $self = shift;
    my ($run) = @_;
    return $self->connect->send_and_get(queue_run => $run);
}

sub spawn {
    my $self = shift;
    my (%params) = @_;

    $params{ipc} = $self->connect->callback;

    return $self->connect->send_and_get(spawn => \%params);
}

sub kill      { shift->send_and_get('kill') }
sub stop      { shift->send_and_get('stop') }
sub abort     { shift->send_and_get('abort') }
sub resources { shift->send_and_get('resources') }

sub process_list   { shift->send_and_get('process_list') }
sub overall_status { shift->send_and_get('overall_status') }

sub active                 { shift->ipc->active }
sub refuse_new_connections { shift->ipc->refuse_new_connections }
sub get_message            { shift->ipc->get_message(@_) }


sub send_and_get {
    my $self = shift;

    my $con = $self->connect;
    my $res = $con->send_and_get(@_);

    return $res->{response} if $res->{api}->{success};

    my @add = map {my $x = $res->{api}->{$_}; $x ? "  $_: $x" : "" } qw/error exception/;
    croak join("\n" => "API Call failed:", @add);
}

1;
