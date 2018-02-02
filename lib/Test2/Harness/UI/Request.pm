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
    $self->{'schema'} = delete $params{schema} or croak "'schema' is a required attribute";

    return $self;
}

sub schema { $_[0]->{schema} }

sub session {
    my $self = shift;

    return $self->{session} if $self->{session};

    my $cookies = $self->cookies;

    my $id = $cookies->{id} or return undef;

    my $session = $self->{schema}->resultset('Session')->find({session_id => $id});

    return undef unless $session && $session->active;

    return $session;
}

my $warned = 0;
sub session_host {
    my $self = shift;

    my $session = $self->session or return undef;

    my $schema = $self->{schema};

    $schema->txn_begin;

    my $host = $schema->resultset('SessionHost')->find_or_create(
        {
            session_ui_id => $session->session_ui_id,
            address       => $self->address,
            agent         => $self->user_agent,
        }
    );

    warn "Update session-host access time" unless $warned++;

    $schema->txn_commit;

    return $host;
}

sub user {
    my $self = shift;

    my $host = $self->session_host or return undef;

    return undef unless $host->user_ui_id;
    return $host->user;
}

1;

__END__

CREATE TABLE session_hosts (
    session_host_ui_id  SERIAL      PRIMARY KEY,
    session_ui_id       INT         NOT NULL REFERENCES sessions(session_ui_id),
    user_ui_id          INTEGER     REFERENCES users(user_ui_id),

    created             TIMESTAMP   NOT NULL DEFAULT now(),
    accessed            TIMESTAMP   NOT NULL DEFAULT now(),

    address             TEXT        NOT NULL,
    agent               TEXT        NOT NULL,

    UNIQUE(session_ui_id, address, agent)
);

