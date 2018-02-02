package Test2::Harness::UI::ControllerRole::UseSession;
use strict;
use warnings;

use Importer Importer => 'import';

use Cookie::Baker;
use Data::GUID();

our @EXPORT = qw/SESSION session add_headers do_once/;

sub SESSION() { 'session' }

sub do_once {
    my $self = shift;

    $self->session;
    $self->request->session_host;
}

sub session {
    my $self = shift;

    return $self->{+SESSION} if $self->{+SESSION};

    unless($self->{+SESSION} = $self->request->session) {
        $self->{+SESSION} = $self->schema->resultset('Session')->create(
            {session_id => Data::GUID->new->as_string},
        );

        $self->request->{session} = $self->{+SESSION};
    }

    return $self->{+SESSION};
}

sub add_headers {
    my $self = shift;

    my $session = $self->session || return;

    return (
        'Set-Cookie' => bake_cookie(
            'id' => {
                value    => $session->session_id,
                httponly => 1,
                expires  => '+1M',
            },
        ),
    );
}

1;
