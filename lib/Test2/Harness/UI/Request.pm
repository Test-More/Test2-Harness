package Test2::Harness::UI::Request;
use strict;
use warnings;

use Carp qw/croak/;

use parent 'Plack::Request';

sub new {
    my $class = shift;
    my %params = @_;

    my $env = delete $params{env} or croak "'env' is a required attribute";

    my $self = $class->SUPER::new($env);
    $self->{'config'} = delete $params{config} or croak "'config' is a required attribute";

    return $self;
}

sub schema { $_[0]->{config} }

sub session {
    my $self = shift;

    return $self->{session} if $self->{session};

    my $cookies = $self->cookies;

    my $id = $cookies->{id} or return undef;

    my $session = $self->{config}->schema->resultset('Session')->find({session_id => $id});

    return undef unless $session && $session->active;

    return $session;
}

my $warned = 0;
sub session_host {
    my $self = shift;

    my $session = $self->session or return undef;

    my $schema = $self->{config}->schema;

    $schema->txn_begin;

    my $host = $schema->resultset('SessionHost')->find_or_create(
        {
            session_id => $session->session_id,
            address    => $self->address,
            agent      => $self->user_agent,
        }
    );

    warn "Update session-host access time" unless $warned++;

    $schema->txn_commit;

    return $host;
}

sub user {
    my $self = shift;

    return $self->{config}->schema->resultset('User')->find({user_id => 1})
        if $self->{config}->single_user;

    my $host = $self->session_host or return undef;

    return undef unless $host->user_id;
    return $host->user;
}

1;
