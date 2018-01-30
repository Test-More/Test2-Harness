package Test2::Harness::UI::Controller::Feed;
use strict;
use warnings;

use Carp qw/croak/;

use Plack::Request;

use Test2::Harness::UI::Import;

use Test2::Harness::UI::Util::HashBase qw/-schema/;

sub init {
    my $self = shift;

    croak "The 'schema' attribute is required" unless $self->{+SCHEMA};
}

sub to_app {
    my $self = shift;

    return sub {
        my $env = shift;

        my $req = Plack::Request->new($env);

        return $self->get($req) if $req->method eq 'GET';
        return $self->post($req) if $req->method eq 'POST';

        return [
            '405',
            [ 'Content-Type' => 'text/plain' ],
            [ "Method not allowed" ],
        ];
    }
}

sub get {
    my $self = shift;
    my ($req) = @_;

    return [
        '200',
        ['Content-Type' => 'text/html']
    ];
}

sub post {
    my $self = shift;
    my ($req) = @_;
}

1;
